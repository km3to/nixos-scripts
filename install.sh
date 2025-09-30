#!/usr/bin/env bash

# Stop on first error
set -e


# --- DEFAULT VALUES ---
DISK="/dev/sda"
USER="km3to"
PASSWD=""
HOST="laptop"
REPO="https://github.com/km3to/nixos-config.git"

RAM_SIZE_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_SIZE_GB=$(( (RAM_SIZE_MB + 1023) / 1024 ))
SWAPFILE_SIZE=$((RAM_SIZE_GB * 1024))
 

# --- PARSE PARAMS ---
# in case of no params
if [ $# -eq 0 ]; then
  echo ""
  echo "Available disks:"
  lsblk -dp -o NAME,SIZE,MODEL,TYPE
  echo ""
  echo "for the -d <disk> (e.g., -d /dev/sda or -d /dev/nvme0n1)"
  echo "For more info: $0 -? | $0 -h | $0 --help"
  exit 0
fi

# with params
while getopts ":d:u:p:h:r:s" opt; do
  case "$opt" in
    d) DISK="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    p) PASSWD="$OPTARG" ;;
    h) HOST="$OPTARG" ;;
    r) REPO="$OPTARG" ;;
    s) SWAPFILE_SIZE="$OPTARG" ;;
    h|\?)  # Help flag (-h or -?)
      echo "Usage: $0 -d <disk> -u <user> -p <passwd> -h <hostname> -r <repo_config> -s <swapfile_size>"
      echo ""
      echo "  -d <disk>   	  optional  default: $DISK"
      echo "  -u <user>  	  optional  default: $USER"
      echo "  -p <passwd>  	  required  default: none" 
      echo "  -h <hostname>  	  optional  default: $HOSTNAME"
      echo "  -r <repo_config>    optional  default: $REPO"
      echo "  -s <swapfile_size>  optional  default: $SWAPFILE_SIZE"
      exit 0
      ;;
  esac
done

# 🔒 Check for required options
if [[ -z "$PASSWD" ]]; then
  echo "Error: -p <passwd> is required."
  echo "Usage: $0 -d <disk> -u <user> -p <passwd> -h <hostname> -r <repo_config> -s <swapfile_size>"
  exit 1
fi


# --- USER EXPLANATION --
echo ""
echo "This script will partition a disk, install NixOS minimal, set in configuration.nix:"
echo "   - bootloader"
echo "   - swapfile"
echo "   - network connection with a hostname"
echo "   - user"
echo "   - timezone and locale"
echo "   - allowUnfree software"
echo "   - commented dconf support for gtk"
echo "   - sets a script that after boot will clone a config repo and set NixOS to use it"
echo "and reboot."
echo ""

# --- DEBUG ---
echo "DISK: $DISK"
echo "USER: $USER"
echo "PASSWD: $PASSWD"
echo "HOST: $HOST"
echo "REPO: $REPO"
echo "SWAPFILE: $SWAPFILE_SIZE"

exit 0


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
RAM_SIZE_GB=$(( (RAM_SIZE_MB + 1023) / 1024 ))
RAM_SIZE_MB=$((RAM_SIZE_GB * 1024))
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

