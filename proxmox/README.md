# Proxmox cloud-init templates & VMs

Two scripts: one that builds Proxmox VM templates from cloud images and another that clone VMs from them. Both run on your laptop and do the work on the Proxmox host over SSH.

| File               | What it does                                                                                                                                                                      |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make-template.sh` | Downloads a Linux cloud image (Ubuntu, Debian, ...), imports it as a VM disk, sets cloud-init (user, SSH key, DHCP), optionally attaches a snippet, and turns it into a template. |
| `new-vm.sh`        | Full-clones a template, sets cores/memory/disk, optionally swaps the snippet, starts the VM and prints its IP once the guest agent reports it.                                    |
| `base.yaml`        | Cloud-init vendor snippet that installs `qemu-guest-agent`, so Proxmox can see the clone's IP.                                                                                    |

## Prerequisites

- **SSH access to the Proxmox host**  with key auth already working. 
	- A `~/.ssh/config` alias is easiest: `--host pve`. You can also set `PVE_HOST` instead of passing `--host`.
- **A public key on your laptop** (the `.pub` file) to install in the clones
- **Proxmox default storage names**: the scripts assume the `local` (directory) storage for images and snippets, `local-lvm` for VM disks, and bridge `vmbr0`
- **A snippet that installs `qemu-guest-agent`** (i.e. `base.yaml`). Without it the scripts still work, but Proxmox can't show the clone's IP. The scripts warn you if it's missing.

## Usage

```bash
chmod +x make-template.sh new-vm.sh

# Build a template (first run downloads the image; later runs reuse it)
./make-template.sh --host pve --vmid 9004 --name ubuntu-24-template \
  --image-url https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  --user admin --ssh-key ~/.ssh/id_ed25519.pub --snippet ./base.yaml

# Clone a VM from it, then SSH in
./new-vm.sh --host pve --template 9004 --vmid 116 --name test-vm --memory 1024 --disk 15
```


**Template Defaults:**
- 1 CPU core
- 512 MB memory
- 10 GB storage
- Key-only login 
 
Disks can only grow, so `new-vm.sh --disk` must be at least the template's size. Run either script with `--help` for all options.
