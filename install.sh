#!/usr/bin/env bash

# Stop on first error
set -e

# --- USER INPUT ---
echo "--- Interactive NixOS Installer ---"
echo "This script will partition a disk, install NixOS from a Git repo, and reboot."
echo ""

# Ask for the Git repository
read -p "Enter your NixOS configuration Git repository URL: " GIT_REPO
if [ -z "$GIT_REPO" ]; then
    echo "Error: Git repository URL cannot be empty."
    exit 1
fi

# Ask for the path to the configuration file inside the repo
DEFAULT_CONFIG_PATH="configuration.nix" # A simpler default
read -p "Path to configuration.nix in repo [${DEFAULT_CONFIG_PATH}]: " CONFIG_FILE_PATH
# If user enters nothing, use the default
CONFIG_FILE_PATH=${CONFIG_FILE_PATH:-$DEFAULT_CONFIG_PATH}

# List available disks and ask the user to choose one
echo ""
echo "Available block devices:"
lsblk -d -o NAME,SIZE,MODEL,TYPE
echo ""
read -p "Enter the device to install NixOS on (e.g., /dev/sda or /dev/nvme0n1): " DISK

# Verify that the chosen device is a valid block device
if [ ! -b "$DISK" ]; then
    echo "Error: '$DISK' is not a valid block device. Please choose from the list above."
    exit 1
fi

# --- FINAL CONFIRMATION (SAFETY CHECK) ---
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! WARNING: This will WIPE ALL DATA on the disk ${DISK}.              !!"
echo "!!                                                                    !!"
echo "!! Make sure you have selected the correct disk and have backups.     !!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Type 'yes' to confirm and proceed with the installation: " CONFIRMATION

if [ "$CONFIRMATION" != "yes" ]; then
    echo "Installation cancelled by user."
    exit 0
fi

# --- PARTITIONING & FORMATTING (UEFI Example) ---
echo ">>> Partitioning ${DISK}..."
# Wipe existing partition table
sgdisk --zap-all ${DISK}

# Create new partitions
sgdisk -n 1:1M:+512M -t 1:ef00 -c 1:boot  ${DISK} # 512MB EFI partition
sgdisk -n 2:0:0     -t 2:8300 -c 2:nixos  ${DISK} # Root partition (rest of the disk)

# Let the kernel know about the new partition table
partprobe ${DISK}
sleep 3 # Give it a moment to settle

# Define partition variables, handling different device name schemes (e.g., sda1 vs. nvme0n1p1)
if [[ $DISK == *"nvme"* ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

echo ">>> Formatting partitions..."
mkfs.fat -F 32 -n boot ${BOOT_PART}
mkfs.ext4 -L nixos ${ROOT_PART}

# --- MOUNTING ---
echo ">>> Mounting filesystems..."
mount ${ROOT_PART} /mnt
mkdir -p /mnt/boot
mount ${BOOT_PART} /mnt/boot

# --- INSTALLATION ---
echo ">>> Generating base NixOS configuration..."
nixos-generate-config --root /mnt

echo ">>> Cloning configuration repository from ${GIT_REPO}..."
# We need git. We can get it temporarily using nix-shell
nix-shell -p git --command "git clone ${GIT_REPO} /mnt/tmp/nixos-config"



# --- SETTING UP CONFIGURATION (CORRECTED) ---
echo ">>> Setting up configuration from repo..."

# Path to the generated hardware config
HARDWARE_CONFIG="/mnt/etc/nixos/hardware-configuration.nix"

# Path where your git repo's config will be placed
TARGET_CONFIG="/mnt/etc/nixos/configuration.nix"

# 1. Copy your configuration from the cloned git repo, replacing the generated one.
cp "/mnt/tmp/nixos-config/${CONFIG_FILE_PATH}" "${TARGET_CONFIG}"

# 2. IMPORTANT: Add the import for hardware-configuration.nix to your config file.
# This adds the line 'imports = [ ./hardware-configuration.nix ];' to the top of the file.
sed -i '1s,^,imports = [ ./hardware-configuration.nix ];\n,' "${TARGET_CONFIG}"

# Clean up the temporary clone
rm -rf /mnt/tmp/nixos-config



# --- DYNAMIC SWAP FILE CONFIGURATION ---
echo ">>> Detecting RAM and configuring swap size..."
# Calculate RAM size in MB
RAM_SIZE_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "System has ${RAM_SIZE_MB}MB of RAM. Setting swap size in configuration.nix..."
# Use sed to replace the placeholder with the actual RAM size.
sed -i "s/__SWAP_SIZE_PLACEHOLDER__/${RAM_SIZE_MB}/" "${CONFIG_ON_TARGET}"


echo ">>> Starting NixOS installation..."
# The --no-root-passwd flag is for automation; you should set a password declaratively
# in your configuration.nix using `users.users.root.initialHashedPassword`.
nixos-install --no-root-passwd

echo ">>> Installation complete! Unmounting filesystems..."
umount -R /mnt

# --- FINAL INSTRUCTIONS ---
echo ""
echo ">>> Installation finished. The swap file size was set to match system RAM."
echo ">>> Your declarative configuration will handle the creation of the swap file on the first boot."
echo ">>> You can now reboot the system."

