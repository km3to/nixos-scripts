#!/usr/bin/env bash

# Stop on first error
set -e

# --- DEFAULT VALUES ---
DISK="/dev/sda"
USER="km3to"
HOST="laptop"
REPO="https://github.com/km3to/nixos.git"
TIMEZONE="Europe/Sofia"
LOCALE="en_US.UTF-8"

# Calculate default swap size based on RAM
RAM_SIZE_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_SIZE_GB=$(( (RAM_SIZE_MB + 1023) / 1024 ))
# Default to RAM size, but not less than 4G
SWAP_SIZE_GB=$(( RAM_SIZE_GB > 4 ? RAM_SIZE_GB : 4 ))

# --- PARSE PARAMS ---
while getopts "d:u:h:r:s:?" opt; do
  case "$opt" in
    d) DISK="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    h) HOST="$OPTARG" ;;
    r) REPO="$OPTARG" ;;
    s) SWAP_SIZE_GB="$OPTARG" ;;
    \?|*) # Help flag
      echo "Usage: $0 [-d <disk>] [-u <user>] [-h <hostname>] [-r <repo>] [-s <swap_gb>]"
      echo ""
      echo "  -d <disk>          Optional. Default: $DISK"
      echo "  -u <user>          Optional. Default: $USER"
      echo "  -h <hostname>      Optional. Default: $HOST"
      echo "  -r <repo>          Optional. Default: $REPO"
      echo "  -s <swap_gb>       Optional. Default: ${SWAP_SIZE_GB}GB"
      exit 0
      ;;
  esac
done

# --- VALIDATION ---
# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (use sudo)" 
   exit 1
fi

# Check if disk exists
if [[ ! -b "$DISK" ]]; then
    echo "ERROR: Disk $DISK does not exist!"
    exit 1
fi

# Validate swap size is a number
if ! [[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Swap size must be a number (got: $SWAP_SIZE_GB)"
    exit 1
fi

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
echo "========================== Available disks ==========================="
lsblk -dp -o NAME,SIZE,MODEL,TYPE
echo "======================================================================"
echo ""
echo "======================= Installation Details ========================="
echo "Disk:           $DISK"
echo "User:           $USER"
echo "Hostname:       $HOST"
echo "Swap Size:      ${SWAP_SIZE_GB}G"
echo "Timezone:       $TIMEZONE"
echo "Locale:         $LOCALE"
echo "Config Repo:    $REPO"
echo "======================================================================"
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! WARNING: This will WIPE ALL DATA on the disk ${DISK}.          !!"
echo "!! Make sure you have selected the correct disk and have backups.  !!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Type 'yes' to confirm and proceed with the installation: " CONFIRMATION

if [ "$CONFIRMATION" != "yes" ]; then
    echo "Installation cancelled by user."
    exit 0
fi

# --- PARTITIONING & FORMATTING (UEFI) ---
echo ">>> Partitioning ${DISK}..."
sgdisk --zap-all ${DISK}
sgdisk -n 1:1M:+1G    -t 1:ef00 -c 1:boot  "${DISK}" # 1GB EFI partition
sgdisk -n 2:0:0       -t 2:8300 -c 2:nixos "${DISK}" # Root partition (rest of disk)

partprobe "${DISK}"
sleep 3

# Determine partition names (handle both SATA/SSD and NVMe naming)
if [[ $DISK == *"nvme"* ]] || [[ $DISK == *"mmcblk"* ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

echo ">>> Formatting partitions..."
mkfs.fat -F 32 -n boot "${BOOT_PART}"
mkfs.ext4 -F -L nixos "${ROOT_PART}"  # Added -F to force format

# --- MOUNTING ---
echo ">>> Mounting filesystems..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
mount "${BOOT_PART}" /mnt/boot

# --- NIXOS CONFIGURATION ---
echo ">>> Generating base NixOS configuration..."
nixos-generate-config --root /mnt

echo ">>> Generating hashed password..."
USER_PASS_HASH=$(nix-shell -p whois --command "mkpasswd -m sha-512 '$PASSWD'")

echo ">>> Writing custom configuration.nix..."
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

  # Enable the SSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";  # Security: disable root login
      PasswordAuthentication = true;
    };
  };

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];  # SSH
  };

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

  # Enable flakes and nix-command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Create a swap file
  swapDevices = [ { device = "/swapfile"; size = ${SWAP_SIZE_GB} * 1024; } ];

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    htop
    tree
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data were taken.
  system.stateVersion = "24.05"; # Update to current stable version

  # Post-boot script to clone your dotfiles
  systemd.services.clone-config-repo = {
    description = "Clone personal NixOS configuration from Git";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;  # Prevent re-running on every boot
    };
    path = [ pkgs.git pkgs.coreutils ];
    script = ''
      set -e
      echo "Waiting 5 seconds for network..."
      sleep 5
      TARGET_DIR="/home/$USER/nixos-config"
      if [ ! -d "\$TARGET_DIR" ]; then
          echo "Cloning NixOS config repo to \$TARGET_DIR..."
          git clone $REPO "\$TARGET_DIR"
          chown -R $USER:users "\$TARGET_DIR"
          echo "Repo cloned successfully to \$TARGET_DIR"
          echo "Run: cd ~/nixos-config && sudo nixos-rebuild switch --flake .#$HOST"
      else
          echo "Config repo directory already exists. Skipping clone."
      fi
    '';
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
echo "========================================================================="
echo ">>> Installation finished successfully!"
echo "========================================================================="
echo ""
echo "Next steps:"
echo "  1. Remove the installation media"
echo "  2. Reboot the system: reboot"
echo "  3. Log in as '$USER' with your password"
echo "  4. Your config repo will be automatically cloned to ~/nixos-config"
echo "  5. Apply your configuration:"
echo "     cd ~/nixos-config"
echo "     sudo nixos-rebuild switch --flake .#$HOST"
echo ""
echo "========================================================================="
