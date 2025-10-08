#!/bin/bash

# KVM Guest Removal Script
# Safely removes VMs and their associated resources

# Function for error handling
function error_exit {
  echo "ERROR: $1" >&2
  exit 1
}

# List all VMs
echo "Fetching list of VMs..."
VMS=($(virsh list --all --name))

if [ ${#VMS[@]} -eq 0 ]; then
    echo "No VMs found on this system."
    exit 0
fi

# Add color to VM names for display
COLORED_VMS=()
for vm in "${VMS[@]}"; do
    COLORED_VMS+=("$(printf "\e[1;36m%s\e[0m" "$vm")")
done
COLORED_VMS+=("$(printf "\e[1;36m%s\e[0m" "Cancel")")

# Display menu
echo "Select a VM to remove:"
echo ""
PS3="Enter selection: "
COLUMNS=1
select COLORED_VM_NAME in "${COLORED_VMS[@]}"; do
    # Strip color codes to get actual VM name
    VM_NAME=$(echo "$COLORED_VM_NAME" | sed 's/\x1b\[[0-9;]*m//g')
    if [[ "$VM_NAME" == "Cancel" ]]; then
        echo "Cancelled."
        exit 0
    elif [[ -n "$VM_NAME" ]]; then
        echo -e "\nYou selected: \e[1;36m$VM_NAME\e[0m"
        break
    else
        echo "Invalid selection. Try again."
    fi
done

# Confirm deletion
echo ""
echo "WARNING: This will permanently delete:"
echo "  - VM definition: $VM_NAME"
echo "  - Disk image: /var/lib/libvirt/images/${VM_NAME}.qcow2"
echo "  - Cloud-init files: /cloud-init/${VM_NAME}/"
echo ""
read -p "Type the VM name '$VM_NAME' to confirm deletion: " CONFIRM

if [[ "$CONFIRM" != "$VM_NAME" ]]; then
    echo "Cancelled. VM name does not match."
    exit 0
fi

echo ""
echo "Removing VM: $VM_NAME"

# Check if VM is running
VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)

if [ "$VM_STATE" = "running" ]; then
    echo "VM is running. Shutting down..."
    virsh destroy "$VM_NAME" || echo "Warning: Failed to force shutdown"
    sleep 2
fi

# Undefine the VM (removes definition)
echo "Removing VM definition..."
virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || {
    echo "Standard undefine failed, trying without storage flag..."
    virsh undefine "$VM_NAME" || error_exit "Failed to undefine VM"
}

# Manually remove disk image if it still exists
DISK_IMG="/var/lib/libvirt/images/${VM_NAME}.qcow2"
if [ -f "$DISK_IMG" ]; then
    echo "Removing disk image: $DISK_IMG"
    rm -f "$DISK_IMG" || echo "Warning: Failed to remove disk image"
else
    echo "Disk image not found (may have been removed by virsh)"
fi

# Remove cloud-init directory
CLOUD_INIT_DIR="/cloud-init/${VM_NAME}"
if [ -d "$CLOUD_INIT_DIR" ]; then
    echo "Removing cloud-init directory: $CLOUD_INIT_DIR"
    rm -rf "$CLOUD_INIT_DIR" || echo "Warning: Failed to remove cloud-init directory"
else
    echo "Cloud-init directory not found (VM may not use cloud-init)"
fi

# Remove cloud-init ISO if it exists separately
CLOUD_INIT_ISO="/var/lib/libvirt/images/${VM_NAME}-cloud-init.iso"
if [ -f "$CLOUD_INIT_ISO" ]; then
    echo "Removing cloud-init ISO: $CLOUD_INIT_ISO"
    rm -f "$CLOUD_INIT_ISO" || echo "Warning: Failed to remove cloud-init ISO"
fi

echo ""
echo "=== Removal Complete ==="
echo "VM '$VM_NAME' has been removed."
echo ""
echo "Verify removal:"
echo "  virsh list --all"
echo "  ls -lh /var/lib/libvirt/images/"
