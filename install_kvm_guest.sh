#!/bin/bash

# Ensure yq is installed (YAML parser for Bash)
# Check if the version output contains the Mike Farah GitHub repo link
YQ_VERSION=$(yq --version)

if echo "$YQ_VERSION" | grep -q "https://github.com/mikefarah/yq/"; then
    echo "Mike Farah's yq detected. Continuing..."
else
    echo "Mike Farah's yq missing."
    echo "This script requires Mike Farah's yq (https://github.com/mikefarah/yq/)."
    echo ""
    read -p "Remove existing yq and install Mike Farah's version? (yes/no): " YQ_CONFIRM

    if [[ "$YQ_CONFIRM" != "yes" ]]; then
        echo "Installation cancelled. Please install Mike Farah's yq manually."
        exit 1
    fi

    echo "Removing other versions and installing Mike Farah's yq..."
    apt-get remove --purge yq -y &> /dev/null
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq &> /dev/null
    chmod +x /usr/bin/yq
    echo "Mike Farah's yq installed successfully."
fi

# Function for error handling
function error_exit {
  echo "ERROR: $1" >&2
  exit 1
}

# Function for creating a single VM instance
function create_vm_instance {
    local VM_BASE_NAME=$1
    local INSTANCE_SUFFIX=$2
    local CONFIG_FILE=$3
    
    # If we have a suffix, append it to the VM name
    if [[ -n "$INSTANCE_SUFFIX" ]]; then
        VM_NAME="${VM_BASE_NAME}${INSTANCE_SUFFIX}"
        echo "Creating VM instance: $VM_NAME"
    else
        VM_NAME="${VM_BASE_NAME}"
        echo "Creating single VM: $VM_NAME"
    fi
    
    # Extract common variables from vm_config.yaml
    DISK_SIZE=$(yq e '.disk_size' "$CONFIG_FILE")
    RAM=$(yq e '.ram' "$CONFIG_FILE")
    VCPUS=$(yq e '.vcpus' "$CONFIG_FILE")
    OS_VARIANT=$(yq e '.os_variant' "$CONFIG_FILE")

    # Check if this is a PXE boot VM
    USE_PXE_BOOT=$(yq e '.use_pxe_boot' "$CONFIG_FILE" || echo "false")

    # Extract the interface information from vm_config.yaml
    INTERFACES=$(yq '.network-config.ethernets | keys | .[]' "$CONFIG_FILE")
    echo "Interfaces: $INTERFACES"
    NETWORK_PARAMS=""

    # Loop through each interface
    for IFACE in $INTERFACES; do
      echo "Processing interface: $IFACE"
      # Extract the bridge name or network for this interface
      BRIDGE=$(yq ".network-config.ethernets.${IFACE}.bridge" "$CONFIG_FILE")
      NETWORK=$(yq ".network-config.ethernets.${IFACE}.network" "$CONFIG_FILE")

      # Add this bridge or network to our network parameters
      if [ "$BRIDGE" != "null" ]; then
        NETWORK_PARAMS+=" --network bridge=\"$BRIDGE\",model=virtio"
      elif [ "$NETWORK" != "null" ]; then
        NETWORK_PARAMS+=" --network network=\"$NETWORK\",model=virtio"
      fi
    done
    echo "Network params: $NETWORK_PARAMS"

    # Path for disk image
    DISK_IMG="/var/lib/libvirt/images/${VM_NAME}.qcow2"

    # Configure VM based on deployment type
    if [ "$USE_PXE_BOOT" = "true" ]; then
        echo "Setting up PXE boot VM..."
        
        # Create an empty disk for the VM
        echo "Creating empty VM disk..."
        qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" || error_exit "Failed to create disk image"
        
        # Determine which interface to use for PXE boot
        PXE_IFACE=$(yq ".pxe_boot_interface" "$CONFIG_FILE" || echo "")
        PXE_PARAMS=""
        
        if [ -n "$PXE_IFACE" ]; then
            # If a specific interface is specified for PXE boot, make sure it's first in boot order
            echo "Using interface $PXE_IFACE for PXE boot"
            PXE_PARAMS="--boot network"
        else
            # Otherwise just use the first interface for PXE boot
            echo "Using first interface for PXE boot"
            PXE_PARAMS="--boot network"
        fi
        
        # Install the PXE boot VM
        echo "Installing PXE boot VM..."
        virt-install \
          --name "$VM_NAME" \
          --ram "$RAM" \
          --vcpus "$VCPUS" \
          --disk path="$DISK_IMG",format=qcow2,device=disk,bus=virtio \
          --pxe \
          $PXE_PARAMS \
          --os-variant "$OS_VARIANT" \
          --noautoconsole || error_exit "Failed to install VM"
          
    else
        # This is a cloud-init based VM - proceed with original logic
        echo "Setting up cloud-init VM..."
        
        # Extract cloud-init specific variables
        IMG_SOURCE=$(yq e '.img_source' "$CONFIG_FILE")
        REDOWNLOAD_IMG=$(yq e '.redownload_img' "$CONFIG_FILE")
        ADMIN_USERNAME=$(yq e '.user-data.users[0].name' "$CONFIG_FILE")
        SSH_KEY=$(yq e '.user-data.users[0].ssh_authorized_keys[0]' "$CONFIG_FILE")

        # Validate SSH key only if it exists
        if [[ "$SSH_KEY" != "null" ]]; then
            if [[ ! "$SSH_KEY" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
                error_exit "Invalid SSH key format in $CONFIG_FILE. Please update ssh_authorized_keys with your public key."
            fi

            # Check for placeholder key
            if [[ "$SSH_KEY" =~ YOUR_PUBLIC_KEY_HERE ]]; then
                error_exit "Please replace the placeholder SSH key with your actual public key in $CONFIG_FILE (find it in ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)"
            fi
        fi

        LOCK_PASSWD=$(yq e '.user-data.users[0].lock_passwd' "$CONFIG_FILE")
        PROMPT_PASSWD=$(yq e '.user-data.users[0].passwd' "$CONFIG_FILE")
        SUDO_CONFIG=$(yq e '.user-data.users[0].sudo' "$CONFIG_FILE" || echo "[]")

        # Ensure parent cloud-init directory exists and is secured
        if [ ! -d "/cloud-init" ]; then
            echo "Creating /cloud-init parent directory..."
            mkdir -p /cloud-init || error_exit "Failed to create /cloud-init parent directory"
            chown root:libvirt-qemu /cloud-init || error_exit "Failed to set ownership on /cloud-init"
            chmod 750 /cloud-init || error_exit "Failed to set permissions on /cloud-init"
        fi

        # Verify /cloud-init has secure permissions (contains sensitive data)
        PARENT_PERMS=$(stat -c "%a" /cloud-init)
        PARENT_GROUP=$(stat -c "%G" /cloud-init)
        if [ "$PARENT_PERMS" != "750" ]; then
            error_exit "Security check failed: /cloud-init has permissions $PARENT_PERMS (expected 750). Run: sudo chmod 750 /cloud-init"
        fi
        if [ "$PARENT_GROUP" != "libvirt-qemu" ]; then
            error_exit "Security check failed: /cloud-init group is $PARENT_GROUP (expected libvirt-qemu). Run: sudo chgrp libvirt-qemu /cloud-init"
        fi

        # Check for cloud-init directory
        CLOUD_INIT_DIR="/cloud-init/${VM_NAME}"

        if [ ! -d "$CLOUD_INIT_DIR" ]; then
            echo "Directory $CLOUD_INIT_DIR does not exist. Creating it..."
            mkdir -p "$CLOUD_INIT_DIR" || error_exit "Failed to create cloud-init directory"
            # Set owner to root and group to libvirt-qemu for hypervisor access
            chown root:libvirt-qemu "$CLOUD_INIT_DIR" || error_exit "Failed to set ownership on $CLOUD_INIT_DIR"
            chmod 750 "$CLOUD_INIT_DIR" || error_exit "Failed to set permissions on $CLOUD_INIT_DIR"
            echo "Directory created with secure permissions (750)."
        else
            echo "Directory $CLOUD_INIT_DIR already exists, verifying permissions..."
            # Verify /cloud-init has secure permissions (owner: root, group: libvirt-qemu, perms: 750)
            DIR_PERMS=$(stat -c "%a" "$CLOUD_INIT_DIR")
            DIR_GROUP=$(stat -c "%G" "$CLOUD_INIT_DIR")
            if [ "$DIR_PERMS" != "750" ]; then
                error_exit "Security check failed: $CLOUD_INIT_DIR has permissions $DIR_PERMS (expected 750). Run: sudo chmod 750 $CLOUD_INIT_DIR"
            fi
            if [ "$DIR_GROUP" != "libvirt-qemu" ]; then
                error_exit "Security check failed: $CLOUD_INIT_DIR group is $DIR_GROUP (expected libvirt-qemu). Run: sudo chgrp libvirt-qemu $CLOUD_INIT_DIR"
            fi
            rm -rf "$CLOUD_INIT_DIR"/* || error_exit "Failed to clean cloud-init directory"
            echo "Prior files removed."
        fi

        # Paths for cloud-init files
        IMG_FILENAME=$(basename "$IMG_SOURCE")
        IMG_TEMPLATE="/var/lib/libvirt/images/templates/$IMG_FILENAME"
        CLOUD_INIT_ISO="${CLOUD_INIT_DIR}/cloud-init.iso"
        META_DATA_PATH="${CLOUD_INIT_DIR}/meta-data"
        USER_DATA_PATH="${CLOUD_INIT_DIR}/user-data"
        NETWORK_CONFIG_PATH="${CLOUD_INIT_DIR}/network-config"

        # Prepare meta-data file
        cat > $META_DATA_PATH <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

        # Create a cleaned version of network-config without bridge parameters
        cat > $NETWORK_CONFIG_PATH <<EOF
version: $(yq e '.network-config.version' "$CONFIG_FILE")
ethernets:
EOF

        # Add each interface without the bridge field
        for IFACE in $INTERFACES; do
          echo "  $IFACE:" >> $NETWORK_CONFIG_PATH
          # Get all properties for this interface and exclude bridge and network
          yq e ".network-config.ethernets.${IFACE} | del(.bridge) | del(.network)" "$CONFIG_FILE" | sed 's/^/    /' >> $NETWORK_CONFIG_PATH
        done

        # Prepare user-data file
        echo "Creating user-data file..."
        cat > $USER_DATA_PATH <<EOF
#cloud-config
users:
  - name: ${ADMIN_USERNAME}
EOF

        # Add SSH key only if provided
        if [[ "$SSH_KEY" != "null" ]]; then
            cat >> $USER_DATA_PATH <<EOF
    ssh_authorized_keys:
      - ${SSH_KEY}
EOF
        # Add disable_root if present in config
        DISABLE_ROOT=$(yq e '.user-data.disable_root' "$CONFIG_FILE")
        if [ "$DISABLE_ROOT" != "null" ]; then
            echo "disable_root: ${DISABLE_ROOT}" >> $USER_DATA_PATH
        fi

        # Continue with remaining user config
        cat >> $USER_DATA_PATH <<EOF
    groups: sudo
    shell: /bin/bash
    lock_passwd: ${LOCK_PASSWD}
EOF

        # Handle password prompting and hashing for user-data file
        if [ "${PROMPT_PASSWD}" = "true" ]; then
            # Only prompt for password for the first instance when creating multiple
            if [[ -z "$INSTANCE_SUFFIX" || "$INSTANCE_SUFFIX" == "-1" ]]; then
                echo "Please enter a password for the user '${ADMIN_USERNAME}':"
                read -s PASSWORD
                echo
                # Cache the password for other instances
                CACHED_PASSWORD="$PASSWORD"
            else
                # Use cached password for additional instances
                PASSWORD="$CACHED_PASSWORD"
            fi
            # Generate the password hash using SHA-512
            #PASSWORD_HASH=$(echo "$PASSWORD" | openssl passwd -6 -stdin)
            PASSWORD_HASH=$(openssl passwd -6 -stdin <<< "$PASSWORD")
            echo "    passwd: ${PASSWORD_HASH}" >> $USER_DATA_PATH
        fi

        # Check for sudo configuration and add it to user-data file
        echo "Parsing sudo configuration..."
        if [ "$(echo "$SUDO_CONFIG" | jq '. | length')" -gt 0 ]; then
            echo "    sudo:" >> $USER_DATA_PATH
            # Iterate over each sudo rule and add it
            echo "$SUDO_CONFIG" | yq e -o=json '.[]' - | while read -r sudo_rule; do
                # Remove quotes from sudo_rule
                sudo_rule_clean=$(echo "$sudo_rule" | tr -d '"')
                echo "      - \"${sudo_rule_clean}\"" >> $USER_DATA_PATH
            done
        fi

        # Check if write_files is present in config
        if yq e '.user-data.write_files' "$CONFIG_FILE" | grep -qv 'null'; then
          # Appending write_files to user-data file
          printf "\nwrite_files:\n" >> $USER_DATA_PATH
          yq e '.user-data.write_files' "$CONFIG_FILE" | sed 's/^/  /' >> $USER_DATA_PATH
        fi

        # Append packages and runcmd to user-data file
        echo "Adding packages, write_files, and runcmd to user-data..."
        cat >> $USER_DATA_PATH <<EOF

packages:
$(yq e '.user-data.packages[] | "  - \(.)"' "$CONFIG_FILE")

runcmd:
$(yq e '.user-data.runcmd[] | "  - \(.)"' "$CONFIG_FILE")
EOF

        # Check for additional files in local cloud-init directory
        if [ -d "cloud-init" ]; then
            echo "Found local cloud-init directory, copying additional files..."
            # Copy any additional files (excluding the standard cloud-init files we just created)
            find cloud-init -type f ! -name "meta-data" ! -name "user-data" ! -name "network-config" -exec cp {} "$CLOUD_INIT_DIR/" \;
            echo "Additional files copied to cloud-init directory."
        fi

        # Create cloud-init iso from files in the /cloud-init/<VM_NAME> directory
        echo "Creating cloud-init ISO..."
        genisoimage -output "${CLOUD_INIT_ISO}" -volid cidata -joliet -rock $CLOUD_INIT_DIR || error_exit "Failed to create cloud-init ISO"

        # Check for base image and download if missing
        if [ ! -f "$IMG_TEMPLATE" ] || [ "$REDOWNLOAD_IMG" = "true" ]; then
          echo "Downloading base image..."
          curl -L -o "$IMG_TEMPLATE" "$IMG_SOURCE" || error_exit "Failed to download base image"
        else
          echo "Base image already exists. Skipping download."
        fi

        # Create the VM guest disk image and resize
        echo "Creating VM disk image..."
        qemu-img convert -f qcow2 -O qcow2 "$IMG_TEMPLATE" "$DISK_IMG" || error_exit "Failed to create disk image"
        qemu-img resize "$DISK_IMG" "$DISK_SIZE" || error_exit "Failed to resize disk image"

        # Install the VM guest
        echo "Installing VM..."
        virt-install \
          --name "$VM_NAME" \
          --ram "$RAM" \
          --vcpus "$VCPUS" \
          --disk path="$DISK_IMG",format=qcow2,device=disk,bus=virtio \
          --disk path="$CLOUD_INIT_ISO",device=cdrom \
          $NETWORK_PARAMS \
          --os-variant "$OS_VARIANT" \
          --import \
          --noautoconsole || error_exit "Failed to install VM"
          
        # Clean up cloud-init cdrom after installation
        echo "Cleaning up cloud-init attachment..."
        sleep 5
        virsh change-media "$VM_NAME" sda --eject --config || echo "Warning: Failed to eject cloud-init media, may need manual cleanup"
    fi

    # Display VM IP addresses
    echo "Fetching IP addresses for $VM_NAME..."
    virsh domifaddr "$VM_NAME" || echo "Warning: Could not get IP addresses for VM, it may still be booting"
    
    echo "VM $VM_NAME deployment complete!"
    echo "-----------------------------------"
}

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build list of directories to search for configs
SEARCH_DIRS=()

# Add custom config directory if specified
[ -n "${KVM_CONFIG_DIR:-}" ] && SEARCH_DIRS+=("$KVM_CONFIG_DIR")

# Add standard directories if they exist
[ -d "$SCRIPT_DIR/examples" ] && SEARCH_DIRS+=("$SCRIPT_DIR/examples")
[ -d "$SCRIPT_DIR/guest_configs" ] && SEARCH_DIRS+=("$SCRIPT_DIR/guest_configs")

# Find all config directories across search paths
OPTIONS=()
for dir in "${SEARCH_DIRS[@]}"; do
    # Verify directory exists
    if [ ! -d "$dir" ]; then
        echo "Warning: Directory $dir does not exist, skipping..."
        continue
    fi

    # Find subdirectories (each is a config)
    while IFS= read -r config_dir; do
        config_name="$(basename "$config_dir")"
        # Store colored name and path separated by tab (path hidden in display)
        OPTIONS+=("$(printf "\e[1;36m%s\e[0m\t%s" "$config_name" "$config_dir")")
    done < <(find "$dir" -maxdepth 1 -type d | grep -vE "$dir$")
done

# Error if no configurations are found
if [ ${#OPTIONS[@]} -eq 0 ]; then
    error_exit "No guest configuration directories found. Each config should be in its own subdirectory containing vm_config.yaml"
fi

# Display menu with custom formatting
echo "Choose a guest config to deploy..."
echo ""
PS3="Enter selection: "
COLUMNS=1
select CHOICE in "${OPTIONS[@]}"; do
    if [[ -n "$CHOICE" ]]; then
        # Extract the path after the tab character
        CONFIG_PATH="${CHOICE##*	}"
        CONFIG_NAME="$(basename "$CONFIG_PATH")"
        echo -e "\nYou selected: \e[1;36m$CONFIG_NAME\e[0m"
        cd "$CONFIG_PATH" || error_exit "Failed to change directory to $CONFIG_PATH"
        break
    else
        echo "Invalid selection. Try again."
    fi
done

# Read the VM configuration from vm_config.yaml
CONFIG_FILE="vm_config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    error_exit "Configuration file $CONFIG_FILE not found!"
fi

# Extract base VM name
VM_BASE_NAME=$(yq e '.meta-data."local-hostname"' "$CONFIG_FILE")

# Check for instance count in the configuration
INSTANCE_COUNT=$(yq e '.instance_count' "$CONFIG_FILE" || echo "1")

# Validate instance count
if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Warning: Invalid instance_count value. Defaulting to 1."
    INSTANCE_COUNT=1
fi

echo "Deploying $INSTANCE_COUNT instance(s) of $VM_BASE_NAME..."

# Handle deployment based on instance count
if [ "$INSTANCE_COUNT" -eq 1 ]; then
    # Deploy a single VM
    create_vm_instance "$VM_BASE_NAME" "" "$CONFIG_FILE"
else
    # Deploy multiple VMs with incremental suffixes
    for i in $(seq 1 "$INSTANCE_COUNT"); do
        create_vm_instance "$VM_BASE_NAME" "-$i" "$CONFIG_FILE"
    done
fi

echo "All VM deployments complete!"
echo ""
echo "=== Getting Started ==="
echo "Connect to VM console:"
echo "  virsh console <vm_name>"
echo ""
echo "Monitor cloud-init progress:"
echo "  ssh admin@<vm_ip> 'tail -f /var/log/cloud-init-output.log'"
echo ""
echo "Check cloud-init status:"
echo "  ssh admin@<vm_ip> 'cloud-init status'"
echo ""
echo "View VM info:"
echo "  virsh domifaddr <vm_name>    # Get IP address"
echo "  virsh dominfo <vm_name>      # Get VM details"