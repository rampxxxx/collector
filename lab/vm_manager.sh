#!/bin/bash

# VM Manager Script using libvirt (virsh) - Simplified for Cloud-init (100% Text)

IMAGE_DIR="/var/lib/libvirt/images"
# Using the official Minimal-VM Cloud image (includes cloud-init)
TEMPLATE_URL="https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2"
TEMPLATE_FILE="./opensuse-tumbleweed-cloud-template.qcow2"

# Configuration variables
SSH_KEY_NAME="collector"
SSH_KEY_PATH="$HOME/.ssh"
VM_RAM="${VM_RAM:-2048}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_SIZE="20G"

usage() {
    echo "Usage: $0 {init|create|list|delete|connect|ssh} [vm_name] [key_path] [network]"
    echo "  init               - Pre-download the OpenSUSE Cloud template image (No sudo needed)"
    echo "  create <name> [key_path] [network] - Create a VM (Default network: default, use bridge name for bridge)"
    echo "  list               - List all VMs"
    echo "  delete <name>      - Stop and remove a VM (including storage)"
    echo "  connect <name>     - Access the VM's serial console"
    echo "  ssh <name> [key_path] - Connect to the VM via SSH (Default key path: $SSH_KEY_PATH)"
    exit 1
}

# Check for dependencies
for cmd in virsh virt-install qemu-img curl; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

case "$1" in
init)
    echo "Initializing VM Manager..."
    if [ ! -f "$TEMPLATE_FILE" ]; then
        echo "Downloading OpenSUSE Tumbleweed Cloud image to local directory..."
        echo "URL: $TEMPLATE_URL"
        # Removed sudo here
        curl -L --retry 5 --progress-bar "$TEMPLATE_URL" -o "$TEMPLATE_FILE"
        if [ $? -eq 0 ]; then
            echo "Successfully downloaded template to $TEMPLATE_FILE"
        else
            echo "Error: Failed to download the image."
            rm -f "$TEMPLATE_FILE"
            exit 1
        fi
    else
        echo "Template image already exists at $TEMPLATE_FILE"
    fi
    ;;

create)
    if [ -z "$2" ]; then
        echo "Error: Please provide a VM name."
        usage
    fi
    
    # Check if VM already exists
    if sudo virsh dominfo "$2" &>/dev/null; then
        echo "VM '$2' already exists."
        STATE=$(sudo virsh domstate "$2")
        if [[ "$STATE" == "running" ]]; then
            echo "VM '$2' is already running. Reusing..."
            exit 0
        else
            echo "VM '$2' is $STATE. Starting..."
            sudo virsh start "$2"
            exit 0
        fi
    fi
    
    # Use custom key path if provided as 3rd argument, otherwise use default
    KEY_DIR="${3:-$SSH_KEY_PATH}"

    # 1. Ensure template exists
    if [ ! -f "$TEMPLATE_FILE" ]; then
        echo "Template not found. Automatically initializing..."
        "$0" init
    fi

    # 2. Get SSH key or generate .pub if missing
    SSH_PUB_KEY_FILE="$KEY_DIR/${SSH_KEY_NAME}.pub"
    SSH_PRIV_KEY_FILE="$KEY_DIR/${SSH_KEY_NAME}"

    if [ ! -f "$SSH_PUB_KEY_FILE" ]; then
        if [ -f "$SSH_PRIV_KEY_FILE" ]; then
            echo "Public key missing. Generating $SSH_PUB_KEY_FILE from private key..."
            ssh-keygen -y -f "$SSH_PRIV_KEY_FILE" > "$SSH_PUB_KEY_FILE"
            chmod 644 "$SSH_PUB_KEY_FILE"
        else
            echo "Error: Neither public nor private SSH key found for '$SSH_KEY_NAME' in $KEY_DIR"
            exit 1
        fi
    fi

    echo "Reading SSH public key from $SSH_PUB_KEY_FILE..."
    SSH_PUB_KEY=$(cat "$SSH_PUB_KEY_FILE")

    # 3. Create disk for new VM by copying template
    VM_DISK="$IMAGE_DIR/$2.qcow2"
    echo "Creating disk for VM '$2'..."
    sudo cp "$TEMPLATE_FILE" "$VM_DISK"

    # 4. Resize the disk
    echo "Resizing disk to $VM_DISK_SIZE..."
    sudo qemu-img resize "$VM_DISK" "$VM_DISK_SIZE"

    # 5. Create cloud-init configuration
    echo "Generating cloud-init configuration..."
    cat <<EOF > user-data
#cloud-config
disable_root: false
ssh_pwauth: False
timezone: Europe/Madrid
locale: es_ES.UTF-8
keyboard:
  layout: es
runcmd:
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - zypper --no-gpg-checks install -y container-selinux
  - zypper --no-gpg-checks install -y https://rpm.rancher.io/k3s/stable/common/microos/noarch/k3s-selinux-1.6-1.sle.noarch.rpm
EOF

    # If we have an SSH key, add it to authorized_keys for root
    if [ ! -z "$SSH_PUB_KEY" ]; then
        cat <<EOF >> user-data
ssh_authorized_keys:
  - $SSH_PUB_KEY
EOF
    else
        echo "Error: SSH_PUB_KEY is empty. With ssh_pwauth: False, you will be locked out of the VM."
        rm user-data meta-data
        exit 1
    fi

    cat <<EOF > meta-data
instance-id: $2
local-hostname: $2
EOF

    # 6. Import the VM with Cloud-Init automation
    NET_CONFIG="${4:-default}"
    if [[ "$NET_CONFIG" == "default" ]]; then
        NET_PARAM="network=default"
    else
        NET_PARAM="bridge=$NET_CONFIG"
    fi

    echo "Importing VM '$2' with network '$NET_PARAM'..."
    sudo virt-install \
        --name "$2" \
        --ram "$VM_RAM" \
        --vcpus "$VM_VCPUS" \
        --os-variant opensusetumbleweed \
        --disk path="$VM_DISK",format=qcow2,bus=virtio \
        --network "$NET_PARAM" \
        --graphics vnc,listen=0.0.0.0 \
        --video vga \
        --serial pty \
        --console pty,target_type=serial \
        --cloud-init user-data=user-data,meta-data=meta-data \
        --import \
        --noautoconsole

    if [ $? -eq 0 ]; then
        rm user-data meta-data
        echo "-------------------------------------------------------"
        echo "SUCCESS: VM '$2' is ready."
        echo "To connect: sudo $0 ssh $2"
        echo "Authentication: SSH Key (${SSH_KEY_NAME}.pub) ONLY"
        echo "Root Password: NONE (Set it manually after logging in)"
        echo "-------------------------------------------------------"
    else
        rm user-data meta-data
        echo "Error: Failed to import VM '$2'."
    fi
    ;;

list)
    echo "Listing all virtual machines..."
    sudo virsh list --all
    ;;

delete)
    if [ -z "$2" ]; then
        echo "Error: Please provide the name of the VM to delete."
        usage
    fi

    echo "Stopping VM '$2' (if running)..."
    sudo virsh destroy "$2" 2>/dev/null

    echo "Undefining VM '$2' and removing storage..."
    sudo virsh undefine "$2" --remove-all-storage

    if [ $? -eq 0 ]; then
        echo "VM '$2' deleted successfully."
    else
        echo "Failed to delete VM '$2'."
    fi
    ;;

connect)
    if [ -z "$2" ]; then
        echo "Error: Please provide the name of the VM to connect to."
        usage
    fi

    echo "Connecting to serial console of VM '$2'..."
    echo "Press Enter once connected to see the login prompt."
    echo "Press Ctrl + ] to exit the console."
    sudo virsh console "$2"
    ;;

ssh)
    if [ -z "$2" ]; then
        echo "Error: Please provide the name of the VM to SSH into."
        usage
    fi
    
    # Use custom key path if provided as 3rd argument, otherwise use default
    KEY_DIR="${3:-$SSH_KEY_PATH}"

    echo "Finding IP address for VM '$2'..."
    VM_IP=$(sudo virsh domifaddr "$2" | grep ipv4 | awk '{print $4}' | cut -d/ -f1)

    if [ -z "$VM_IP" ]; then
        echo "Error: Could not find an IP address for VM '$2'."
        echo "Make sure the VM is running and has had time to boot."
        exit 1
    fi

    echo "Connecting to root@$VM_IP using SSH key: $KEY_DIR/${SSH_KEY_NAME}..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_DIR/${SSH_KEY_NAME}" "root@$VM_IP"
    ;;

*)
    usage
    ;;
esac
