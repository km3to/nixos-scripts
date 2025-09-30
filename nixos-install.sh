#!/usr/bin/env bash

# Stop on first error
set -e

# --- DEFAULT VALUES ---
DISK="/dev/sda"
USER="km3to"
HOST="laptop"
REPO="https://github.com/km3to/nixos-config.git"
TIMEZONE="Europe/Sofia"
LOCALE="en_US.UTF-8"

# Calculate default swap size based on RAM
RAM_SIZE_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_SIZE_GB=$(( (RAM_SIZE_MB + 1023) / 1024 ))
# Default to RAM size, but not less than 4G
SWAP_SIZE_GB=$(( RAM_SIZE_GB > 4 ? RAM_SIZE_GB : 4 ))


# --- PARSE PARAMS ---
# with params
while getopts "d:u:h:r:s:?" opt; do
  case "$opt" in
    d) DISK="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    h) HOST="$OPTARG" ;;
    r) REPO="$OPTARG" ;;
    s) SWAP_SIZE_GB="$OPTARG" ;;
    \?|*) # Help flag (-? or any other)
      echo "Usage: $0 [-d <disk>] [-u <user>] [-h <hostname>] [-s <swap_gb>]"
      echo ""
      echo "  -d <disk>          Optional. Default: $DISK"
      echo "  -u <user>          Optional. Default: $USER"
      echo "  -r <repo>		 Optional. Default: $REPO"
      echo "  -h <hostname>      Optional. Default: $HOST"
      echo "  -s <swap_gb>       Optional. Default: ${SWAP_SIZE_GB}GB"
      exit 0
      ;;
  esac
done

# --- SECURE PASSWORD INPUT ---
PASSWD=""
PASSWD_CONFIRM=""
while true; do
    read -s -p "Enter password for user '$USER': " PASSWD
    echo
    read -s -p "Confirm password: " PASSWD_CONFIRM
    echo
    if [ "$PASSWD" = "$PASSWD_CONFIRM" ]; then
        if [ -z "$PASSWD" ]; then
            echo "Password cannot be empty. Please try again."
        else
            break
        fi
    else
        echo "Passwords do not match. Please try again."
    fi
done

# --- USER EXPLANATION & FINAL CONFIRMATION ---
echo ""
echo "========================== Available disks! ==========================="
lsblk -dp -o NAME,SIZE,MODEL,TYPE
echo "======================================================================="
echo ""
echo "======================== Installation Details ========================="
echo "Disk:           $DISK"
echo "User:           $USER"
echo "Hostname:       $HOST"
echo "Swap Size:      ${SWAP_SIZE_GB}G"
echo "Timezone:       $TIMEZONE"
echo "Locale:         $LOCALE"
echo "Config Repo:    $REPO"
echo "======================================================================="
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! WARNING: This will WIPE ALL DATA on the disk ${DISK}.            !!"
echo "!! Make sure you have selected the correct disk and have backups.    !!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Type 'yes' to confirm and proceed with the installation: " CONFIRMATION

if [ "$CONFIRMATION" != "yes" ]; then
    echo "Installation cancelled by user."
    exit 0
fi

exit 0

# --- PARTITIONING & FORMATTING (UEFI Example) ---
echo ">>> Partitioning ${DISK}..."
sgdisk --zap-all ${DISK}
sgdisk -n 1:1M:+1G    -t 1:ef00 -c 1:boot  "${DISK}" # 1GB EFI partition
sgdisk -n 2:0:0       -t 2:8300 -c 2:nixos "${DISK}" # Root partition (rest of the disk)

partprobe "${DISK}"
sleep 3

if [[ $DISK == *"nvme"* ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

echo ">>> Formatting partitions..."
mkfs.fat -F 32 -n boot "${BOOT_PART}"
mkfs.ext4 -L nixos "${ROOT_PART}"

# --- MOUNTING ---
echo ">>> Mounting filesystems..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
mount "${BOOT_PART}" /mnt/boot

# --- NIXOS CONFIGURATION ---
echo ">>> Generating base NixOS configuration..."
nixos-generate-config --root /mnt

echo ">>> Generating hashed password..."
# We need mkpasswd, which is in the `whois` package
USER_PASS_HASH=$(nix-shell -p whois --command "mkpasswd -m sha-512 '$PASSWD'")

echo ">>> Writing custom configuration.nix..."
# Using a heredoc to create the configuration file from scratch.
# This is cleaner than using `sed` for many changes.
cat > /mnt/etc/nixos/configuration.nix << EOF
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking
  networking.hostName = "$HOST";
  networking.networkmanager.enable = true;

  # Timezone and Locale
  time.timeZone = "$TIMEZONE";
  i18n.defaultLocale = "$LOCALE";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "$LOCALE";
    LC_IDENTIFICATION = "$LOCALE";
    LC_MEASUREMENT = "$LOCALE";
    LC_MONETARY = "$LOCALE";
    LC_NAME = "$LOCALE";
    LC_NUMERIC = "$LOCALE";
    LC_PAPER = "$LOCALE";
    LC_TELEPHONE = "$LOCALE";
    LC_TIME = "$LOCALE";
  };

  # Users and Passwords
  users.users.$USER = {
    isNormalUser = true;
    description = "$USER";
    extraGroups = [ "networkmanager" "wheel" ];
    initialHashedPassword = "$USER_PASS_HASH";
  };
  # Allow wheel group to use sudo
  security.sudo.wheelNeedsPassword = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Create a swap file
  swapDevices = [ { device = "/swapfile"; size = ${SWAP_SIZE_GB} * 1024; } ];

  # List packages installed in system profile. To search, run:
  # \$ nix search wget
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?

  # Post-boot script to clone your dotfiles
  systemd.services.clone-config-repo = {
    description = "Clone personal NixOS configuration from Git";
    after = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "$USER";
      # This script will only run once.
      # It checks if the target directory already exists.
      ExecStart = pkgs.writeShellScript "clone-repo" ''
        set -e
        TARGET_DIR="/home/$USER/nixos-config"
        if [ ! -d "\$TARGET_DIR" ]; then
            echo "Cloning NixOS config repo to \$TARGET_DIR..."
            su $USER -c "git clone $REPO \$TARGET_DIR"
            echo "Repo cloned. Please inspect it and then run 'sudo nixos-rebuild switch --flake .#$HOST'"
        else
            echo "Config repo directory already exists. Skipping clone."
        fi
      '';
    };
  };
}
EOF

# --- INSTALLATION ---
echo ">>> Starting NixOS installation..."
nixos-install --no-root-passwd

echo ">>> Installation complete! Unmounting filesystems..."
umount -R /mnt

# --- FINAL INSTRUCTIONS ---
echo ""
echo ">>> Installation finished."
echo ">>> You can now remove the installation media and reboot the system."
echo ">>> After rebooting and logging in as '$USER', your config repo will be in ~/nixos-config."
