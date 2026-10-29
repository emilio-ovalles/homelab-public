#!/usr/bin/env bash
# make-template.sh — build a Proxmox cloud-init VM template, run from laptop
set -euo pipefail

usage() {
  cat <<'EOF'
Build a Proxmox cloud-init VM template from a cloud image URL.
Runs on your laptop; does the work on the Proxmox host over SSH.

Usage:
  make-template.sh --host <user@host> --vmid <id> --name <name> \
                   --image-url <url> --user <username> --ssh-key <path> [options]

Required:
  --host <user@host>     Proxmox host to SSH into (or set PVE_HOST)
  --vmid <id>            VM ID for the template (e.g. 9003)
  --name <name>          Template name (letters, digits, hyphens)
  --image-url <url>      Cloud image URL (.img or .qcow2)
  --user <username>      Default user cloud-init creates in clones
  --ssh-key <path>       Public key on THIS machine to install in clones

Optional:
  --snippet <path>       Local cloud-config file to upload and attach as the
                         vendor snippet (overwrites a host copy of the same name)
  --ci-password <pw>     Console password for the user (default: none, key-only)
  --disk <GB>            Disk size in GB (default: 10)
  --memory <MB>          Memory in MB (default: 512)
  --cores <n>            CPU cores (default: 1)
  -h, --help             Show this help

Example:
  make-template.sh --host root@pve.example.lan --vmid 9003 --name debian-12-template \
    --image-url https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 \
    --user admin --ssh-key ~/.ssh/id_ed25519.pub --snippet ./base.yaml
EOF
}

die() { echo "error: $*" >&2; echo "run with --help for usage" >&2; exit 1; }

warn_no_agent() {
  cat >&2 <<EOF
warning: $1
  Most cloud images don't include qemu-guest-agent. Clones from this template will
  still boot and accept SSH, but until the agent is installed:
    - Proxmox won't show the clone's IP (find it in UniFi or via ip neigh)
    - Shutdown from Proxmox falls back to an ACPI signal instead of a clean OS shutdown
    - Backups can't pause disk writes, so snapshots may be inconsistent
  Fix: attach a snippet that installs qemu-guest-agent, here or on each clone.
EOF
}

# Defaults
HOST=${PVE_HOST:-}
CI_PASSWORD="" DISK=10 MEMORY=512 CORES=1 SNIPPET=""
ID="" NAME="" URL="" CI_USER="" SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host|--vmid|--name|--image-url|--user|--ssh-key|--snippet|--ci-password|--disk|--memory|--cores)
      [[ $# -ge 2 && "$2" != --* ]] || die "$1 needs a value"
      case "$1" in
        --host)        HOST=$2 ;;
        --vmid)        ID=$2 ;;
        --name)        NAME=$2 ;;
        --image-url)   URL=$2 ;;
        --user)        CI_USER=$2 ;;
        --ssh-key)     SSH_KEY=$2 ;;
        --snippet)     SNIPPET=$2 ;;
        --ci-password) CI_PASSWORD=$2 ;;
        --disk)        DISK=$2 ;;
        --memory)      MEMORY=$2 ;;
        --cores)       CORES=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

# --- local validation (before touching the host) ---
[[ -n "$HOST" ]]    || die "--host is required (or set PVE_HOST)"
[[ -n "$ID" ]]      || die "--vmid is required"
[[ -n "$NAME" ]]    || die "--name is required"
[[ -n "$URL" ]]     || die "--image-url is required"
[[ -n "$CI_USER" ]] || die "--user is required"
[[ -n "$SSH_KEY" ]] || die "--ssh-key is required"

[[ "$ID" =~ ^[0-9]+$ ]]          || die "--vmid must be a number"
[[ "$DISK" =~ ^[0-9]+$ ]]        || die "--disk must be a whole number of GB"
[[ "$MEMORY" =~ ^[0-9]+$ ]]      || die "--memory must be a number of MB"
[[ "$CORES" =~ ^[0-9]+$ ]]       || die "--cores must be a number"
[[ "$NAME" =~ ^[A-Za-z0-9-]+$ ]] || die "--name may only contain letters, digits, and hyphens"

[[ -f "$SSH_KEY" ]] || die "ssh key not found: $SSH_KEY"
grep -qE '^(ssh-|ecdsa-|sk-)' "$SSH_KEY" \
  || die "$SSH_KEY doesn't look like a PUBLIC key (did you pass the private key? use the .pub file)"
PUBKEY=$(cat "$SSH_KEY")

SNIPPET_NAME="" SNIPPET_B64=""
if [[ -n "$SNIPPET" ]]; then
  [[ -f "$SNIPPET" ]] || die "snippet not found: $SNIPPET"
  [[ "$(head -1 "$SNIPPET")" == "#cloud-config" ]] || die "$SNIPPET must start with the line #cloud-config"
  SNIPPET_NAME=$(basename "$SNIPPET")
  [[ "$SNIPPET_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "snippet file name may only contain letters, digits, . _ -"
  SNIPPET_B64=$(base64 < "$SNIPPET" | tr -d '\n')
  grep -q 'qemu-guest-agent' "$SNIPPET" \
    || warn_no_agent "snippet $SNIPPET_NAME doesn't mention qemu-guest-agent"
else
  warn_no_agent "no --snippet given"
fi

# --- remote work: one SSH connection, args passed safely quoted ---
ARGS=$(printf '%q ' "$ID" "$NAME" "$URL" "$CI_USER" "$PUBKEY" "$CI_PASSWORD" \
  "$DISK" "$MEMORY" "$CORES" "$SNIPPET_NAME" "$SNIPPET_B64")

echo "==> connecting to $HOST"
ssh "$HOST" "bash -s -- $ARGS" <<'REMOTE'
set -euo pipefail
ID=$1 NAME=$2 URL=$3 CI_USER=$4 PUBKEY=$5 CI_PASSWORD=$6
DISK=$7 MEMORY=$8 CORES=$9 SNIPPET_NAME=${10} SNIPPET_B64=${11}

fail() { echo "error (on host): $*" >&2; exit 1; }

command -v qm >/dev/null || fail "qm not found — is this a Proxmox host?"
if qm status "$ID" &>/dev/null; then fail "VM $ID already exists"; fi

# Snippet: enable the content type on 'local' if needed (keeping existing types), then upload
if [[ -n "$SNIPPET_NAME" ]]; then
  CONTENT=$(pvesh get /storage/local --output-format json \
    | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
  [[ -n "$CONTENT" ]] || fail "couldn't read content types for storage 'local'"
  case ",$CONTENT," in
    *,snippets,*) echo "==> snippets already enabled on local ($CONTENT)" ;;
    *) echo "==> enabling snippets on local: $CONTENT -> $CONTENT,snippets"
       pvesm set local --content "$CONTENT,snippets" ;;
  esac
  mkdir -p /var/lib/vz/snippets
  printf '%s' "$SNIPPET_B64" | base64 -d > "/var/lib/vz/snippets/$SNIPPET_NAME"
  echo "==> uploaded snippet /var/lib/vz/snippets/$SNIPPET_NAME"
fi

# Public key: write to a temp file for qm, removed on exit
KEYFILE=$(mktemp)
trap 'rm -f "$KEYFILE"' EXIT
printf '%s\n' "$PUBKEY" > "$KEYFILE"

IMG=/var/lib/vz/template/iso/$(basename "$URL")
if [[ -f "$IMG" ]]; then
  echo "==> using cached image $IMG"
else
  echo "==> downloading $URL"
  wget -q --show-progress -O "$IMG" "$URL"
fi

echo "==> creating VM $ID ($NAME): ${CORES} core(s), ${MEMORY}MB, ${DISK}G disk"
qm create "$ID" --name "$NAME" --memory "$MEMORY" --cores "$CORES" \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single \
  --agent enabled=1 --ostype l26
qm disk import "$ID" "$IMG" local-lvm
qm set "$ID" --scsi0 "local-lvm:vm-${ID}-disk-0"
qm resize "$ID" scsi0 "${DISK}G"
qm set "$ID" --ide2 local-lvm:cloudinit --boot order=scsi0
qm set "$ID" --serial0 socket --vga serial0
qm set "$ID" --ciuser "$CI_USER" --sshkeys "$KEYFILE" --ipconfig0 ip=dhcp

[[ -z "$CI_PASSWORD" ]] || qm set "$ID" --cipassword "$CI_PASSWORD"
[[ -z "$SNIPPET_NAME" ]] || qm set "$ID" --cicustom "vendor=local:snippets/$SNIPPET_NAME"

qm template "$ID"
echo "==> template $NAME ($ID) ready"
REMOTE
