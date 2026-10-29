#!/usr/bin/env bash
# new-vm.sh — clone a VM from a Proxmox cloud-init template, run from your laptop
set -euo pipefail

usage() {
  cat <<'EOF'
Clone a new VM from a Proxmox cloud-init template, start it, and print its IP.
Runs on your laptop; does the work on the Proxmox host over SSH.

Usage:
  new-vm.sh --host <user@host> --template <id> --vmid <id> --name <name> [options]

Required:
  --host <user@host>     Proxmox host to SSH into (or set PVE_HOST)
  --template <id>        Template VM ID to clone from (e.g. 9002)
  --vmid <id>            VM ID for the new VM (e.g. 103)
  --name <name>          VM name, also its hostname (letters, digits, hyphens)

Optional:
  --cores <n>            CPU cores (default: same as template)
  --memory <MB>          Memory in MB (default: same as template)
  --disk <GB>            Disk size in GB, grow only (default: same as template)
  --snippet <path>       Local cloud-config file to upload and attach to this VM.
                         Replaces the template's snippet for this VM.
  --no-start             Create the VM but don't start it
  --no-wait              Start it but don't wait for the IP
  -h, --help             Show this help

Example:
  new-vm.sh --host pve --template 9002 --vmid 103 --name victim-web \
    --memory 1024 --disk 15 --snippet ./wazuh-agent.yaml
EOF
}

die() { echo "error: $*" >&2; echo "run with --help for usage" >&2; exit 1; }

HOST=${PVE_HOST:-}
TEMPLATE="" ID="" NAME="" CORES="" MEMORY="" DISK="" SNIPPET=""
START=1 WAIT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)  usage; exit 0 ;;
    --no-start) START=0; WAIT=0; shift ;;
    --no-wait)  WAIT=0; shift ;;
    --host|--template|--vmid|--name|--cores|--memory|--disk|--snippet)
      [[ $# -ge 2 && "$2" != --* ]] || die "$1 needs a value"
      case "$1" in
        --host)     HOST=$2 ;;
        --template) TEMPLATE=$2 ;;
        --vmid)     ID=$2 ;;
        --name)     NAME=$2 ;;
        --cores)    CORES=$2 ;;
        --memory)   MEMORY=$2 ;;
        --disk)     DISK=$2 ;;
        --snippet)  SNIPPET=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

# --- local validation ---
[[ -n "$HOST" ]]     || die "--host is required (or set PVE_HOST)"
[[ -n "$TEMPLATE" ]] || die "--template is required"
[[ -n "$ID" ]]       || die "--vmid is required"
[[ -n "$NAME" ]]     || die "--name is required"

[[ "$TEMPLATE" =~ ^[0-9]+$ ]]    || die "--template must be a number"
[[ "$ID" =~ ^[0-9]+$ ]]          || die "--vmid must be a number"
[[ "$NAME" =~ ^[A-Za-z0-9-]+$ ]] || die "--name may only contain letters, digits, and hyphens"
[[ -z "$CORES"  || "$CORES"  =~ ^[0-9]+$ ]] || die "--cores must be a number"
[[ -z "$MEMORY" || "$MEMORY" =~ ^[0-9]+$ ]] || die "--memory must be a number of MB"
[[ -z "$DISK"   || "$DISK"   =~ ^[0-9]+$ ]] || die "--disk must be a whole number of GB"

SNIPPET_NAME="" SNIPPET_B64=""
if [[ -n "$SNIPPET" ]]; then
  [[ -f "$SNIPPET" ]] || die "snippet not found: $SNIPPET"
  [[ "$(head -1 "$SNIPPET")" == "#cloud-config" ]] || die "$SNIPPET must start with the line #cloud-config"
  SNIPPET_NAME=$(basename "$SNIPPET")
  [[ "$SNIPPET_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "snippet file name may only contain letters, digits, . _ -"
  SNIPPET_B64=$(base64 < "$SNIPPET" | tr -d '\n')
  if ! grep -q 'qemu-guest-agent' "$SNIPPET"; then
    cat >&2 <<EOF
warning: snippet $SNIPPET_NAME doesn't mention qemu-guest-agent.
  It replaces the template's snippet for this VM, so the agent may not get installed:
  no IP in Proxmox, no clean shutdown, no consistent backups. --no-wait recommended.
EOF
  fi
fi

# --- remote work: one SSH connection; progress shown live, only the IP is captured ---
ARGS=$(printf '%q ' "$TEMPLATE" "$ID" "$NAME" "$CORES" "$MEMORY" "$DISK" \
  "$SNIPPET_NAME" "$SNIPPET_B64" "$START" "$WAIT")

echo "==> connecting to $HOST" >&2
OUT=$(ssh "$HOST" "bash -s -- $ARGS" <<'REMOTE'
set -euo pipefail
TEMPLATE=$1 ID=$2 NAME=$3 CORES=$4 MEMORY=$5 DISK=$6
SNIPPET_NAME=$7 SNIPPET_B64=$8 START=$9 WAIT=${10}

# Everything goes to stderr (your terminal); only the final IP is written to fd 3
exec 3>&1 1>&2

log()  { echo "$*"; }
fail() { echo "error (on host): $*" >&2; exit 1; }

command -v qm >/dev/null || fail "qm not found — is this a Proxmox host?"
qm config "$TEMPLATE" &>/dev/null || fail "template $TEMPLATE doesn't exist"
qm config "$TEMPLATE" | grep -q '^template: 1' || fail "VM $TEMPLATE is not a template"
if qm status "$ID" &>/dev/null; then fail "VM $ID already exists"; fi

# Disks only grow: refuse a size smaller than the template's before cloning
if [[ -n "$DISK" ]]; then
  CUR=$(qm config "$TEMPLATE" | sed -n 's/^scsi0:.*size=\([0-9]*\)G.*/\1/p')
  if [[ -n "$CUR" && "$DISK" -lt "$CUR" ]]; then
    fail "--disk ${DISK}G is smaller than the template's ${CUR}G (disks can only grow)"
  fi
fi

if [[ -n "$SNIPPET_NAME" ]]; then
  CONTENT=$(pvesh get /storage/local --output-format json \
    | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
  [[ -n "$CONTENT" ]] || fail "couldn't read content types for storage 'local'"
  case ",$CONTENT," in
    (*,snippets,*) ;;
    (*) log "==> enabling snippets on local: $CONTENT -> $CONTENT,snippets"
       pvesm set local --content "$CONTENT,snippets" ;;
  esac
  mkdir -p /var/lib/vz/snippets
  printf '%s' "$SNIPPET_B64" | base64 -d > "/var/lib/vz/snippets/$SNIPPET_NAME"
  log "==> uploaded snippet /var/lib/vz/snippets/$SNIPPET_NAME"
fi

log "==> cloning template $TEMPLATE -> $ID ($NAME)"
qm clone "$TEMPLATE" "$ID" --name "$NAME" --full

[[ -z "$CORES" ]]  || qm set "$ID" --cores "$CORES"
[[ -z "$MEMORY" ]] || qm set "$ID" --memory "$MEMORY"
[[ -z "$DISK" ]]   || qm resize "$ID" scsi0 "${DISK}G"
[[ -z "$SNIPPET_NAME" ]] || qm set "$ID" --cicustom "vendor=local:snippets/$SNIPPET_NAME"

if [[ "$START" == 1 ]]; then
  log "==> starting $ID"
  qm start "$ID"
fi

# Wait for the guest agent to report an IPv4 address (first boot runs apt, so allow time)
if [[ "$WAIT" == 1 ]]; then
  log "==> waiting for the guest agent to report an IP (up to 5 min)"
  for _ in $(seq 1 60); do
    IP=$(qm guest cmd "$ID" network-get-interfaces 2>/dev/null \
      | grep -oE '"ip-address" *: *"[0-9]+(\.[0-9]+){3}"' \
      | grep -oE '[0-9]+(\.[0-9]+){3}' | grep -v '^127\.' | head -1 || true)
    if [[ -n "$IP" ]]; then
      USER_=$(qm config "$ID" | sed -n 's/^ciuser: //p')
      echo "$IP ${USER_:-}" >&3
      exit 0
    fi
    sleep 5
  done
  log "warning: no IP reported after 5 minutes (agent may not be installed); check UniFi"
fi
REMOTE
)

if [[ -n "$OUT" ]]; then
  read -r IP CI_USER <<<"$OUT"
  # The IP may have belonged to an earlier, destroyed VM; drop its stale host key
  ssh-keygen -R "$IP" >/dev/null 2>&1 || true
  echo "==> $NAME ($ID) is up at $IP" >&2
  echo "    ssh ${CI_USER:+$CI_USER@}$IP" >&2
else
  echo "==> $NAME ($ID) created" >&2
fi
