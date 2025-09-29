#!/usr/bin/env bash
set -e

CONFIG_DIR=~/nixos-config
HOST=$(hostname)

# Clone flake
git clone https://github.com/you/nixos-config "$CONFIG_DIR"

# Move hardware config into flake
mv /etc/nixos/hardware-configuration.nix "$CONFIG_DIR/hosts/$HOST/hardware-configuration.nix"

# Clean up
sudo rm -rf /etc/nixos

# Rebuild system
sudo nixos-rebuild switch --flake "$CONFIG_DIR#$HOST"

