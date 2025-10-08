# kvm-cloud-init-automation

Automated KVM guest provisioning using cloud-init and virt-install

## Overview

This project provides bash automation for deploying KVM virtual machines using cloud-init based images. It supports declarative YAML configuration, automated network setup, and both single and multi-instance deployments.

## Features

- **Declarative Configuration**: Define VMs using simple YAML files
- **Cloud-init Integration**: Automated initial configuration via cloud-init
- **Network Flexibility**: Support for bridged networks, NAT, and DHCP
- **Multi-instance Deployment**: Deploy multiple identical VMs in one command
- **PXE Boot Support**: Alternative deployment method for network-based installation
- **Safe Removal**: Interactive VM removal with confirmation safeguards

## Requirements

- **Host System**: Debian/Ubuntu (apt-based)
- **Hypervisor**: KVM/QEMU with libvirt
- **Dependencies**:
  - `virt-install`
  - `virsh`
  - `genisoimage`
  - `qemu-img`
  - Mike Farah's `yq` (auto-installed if missing)

## Quick Start

1. **Clone the repository**
   ```bash
   git clone https://github.com/silentarcher/kvm-cloud-init-automation.git
   cd kvm-cloud-init-automation
   ```

2. **Deploy a VM** (choose one option)

   **Option A: Password authentication only** (easiest for quickly deploying a lab vm)
   ```bash
   sudo ./install_kvm_guest.sh
   # Select 'basic-vm' from the menu
   ```

   **Option B: SSH key authentication** (recommended for better SSH security)

   First, add your SSH public key to the config:
   ```bash
   cat ~/.ssh/id_ed25519.pub  # Copy your public key
   vim ./examples/basic-vm-ssh-key/vm_config.yaml  # Replace YOUR_PUBLIC_KEY_HERE
   ```

   Then deploy:
   ```bash
   sudo ./install_kvm_guest.sh
   # Select 'basic-vm-ssh-key' from the menu
   ```

3. **Remove a VM** (when needed)
   ```bash
   sudo ./remove_kvm_guest.sh
   ```
   Select the vm name for removal and follow the prompts.

## Configuration

VM configurations are stored in YAML files within the `examples/` or `guest_configs/` directories. Each configuration defines:

- VM resources (CPU, RAM, disk)
- Network configuration
- Cloud-init user-data (users, packages, scripts)
- OS variant and image source

### Example Configuration Structure

```
examples/
├── ubuntu-server/
│   └── vm_config.yaml
├── debian/
│   └── vm_config.yaml
└── custom-vm/
    └── vm_config.yaml
```

### Custom Configuration Directory

You can store configurations outside the repository:

```bash
export KVM_CONFIG_DIR=/path/to/my/configs
sudo -E ./install_kvm_guest.sh
```

## Configuration Examples

### Basic DHCP VM (Easiest)

```yaml
meta-data:
  local-hostname: my-vm

disk_size: 20G
ram: 2048
vcpus: 2
os_variant: ubuntu24.04
img_source: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
redownload_img: false

network-config:
  version: 2
  ethernets:
    enp1s0:
      network: "default"  # Uses libvirt default NAT network
      dhcp4: true

user-data:
  users:
    - name: admin
      ssh_authorized_keys:
        - ssh-ed25519 YOUR_PUBLIC_KEY_HERE user@hostname
      groups: sudo
      shell: /bin/bash
      sudo:
        - "ALL=(ALL) ALL"
      lock_passwd: false
      passwd: true  # Prompts for password during deployment

  packages:
    - qemu-guest-agent
    - vim

  runcmd:
    - systemctl start qemu-guest-agent
```

### Static IP VM

```yaml
network-config:
  version: 2
  ethernets:
    enp1s0:
      bridge: "br0"  # Connect to existing bridge
      addresses:
        - 192.0.2.10/24
      gateway4: 192.0.2.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 1.0.0.1
```

### Multi-instance Deployment

Add to your `vm_config.yaml`:

```yaml
instance_count: 3
```

This deploys 3 identical VMs named `hostname-1`, `hostname-2`, `hostname-3`.

## Security Considerations

### SSH Key Validation

The installer validates SSH keys before deployment:
- Checks for valid key format (`ssh-rsa`, `ssh-ed25519`, `ssh-ecdsa`)
- Detects placeholder keys and prevents deployment
- Provides helpful error messages with instructions

### Password Handling

- Passwords are prompted interactively (not stored in configs)
- Hashed using SHA-512 before writing to cloud-init
- Uses here-string to avoid process argument exposure
- Multi-VM deployments prompt once and reuse securely

### VM Removal Safety

The removal script requires:
- Exact VM name confirmation
- Explicit typing to prevent accidental deletion

## Network Configuration

The script supports multiple network types:

- **NAT (default)**: Uses libvirt's `default` network
- **Bridged**: Connects to existing bridge interfaces
- **DHCP or Static**: Flexible IP assignment

Network interface names (e.g., `enp1s0`, `ens3`) must match what the guest OS expects. Consult your cloud image documentation.

## Troubleshooting

### Check VM status
```bash
virsh list --all
virsh dominfo <vm-name>
```

### Monitor cloud-init progress
```bash
virsh console <vm-name>
# or via SSH:
ssh admin@<vm-ip> 'cloud-init status --wait'
```

### View cloud-init logs
```bash
ssh admin@<vm-ip> 'tail -f /var/log/cloud-init-output.log'
```

### Get VM IP address
```bash
virsh domifaddr <vm-name>
```

## File Locations

- **VM Disks**: `/var/lib/libvirt/images/<vm-name>.qcow2`
- **Cloud-init ISOs**: `/cloud-init/<vm-name>/`
- **Image Templates**: `/var/lib/libvirt/images/templates/`

## License

GPL-3.0

## Contributing

Contributions welcome! Please ensure:
- Configs use placeholder SSH keys (not real keys)
- Network examples use RFC 5737 documentation IPs
- Test on Debian/Ubuntu before submitting

## Author

[@silentarcher](https://github.com/silentarcher)
