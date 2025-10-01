#!/usr/bin/env bash

echo "=== DISK LAYOUT ==="
lsblk -f
echo ""

echo "=== DISK USAGE ==="
df -h
echo ""

echo "=== SWAP STATUS ==="
swapon --show
free -h
echo ""

echo "=== HOSTNAME ==="
hostnamectl
echo ""

echo "=== NETWORK TEST ==="
ping -c 3 google.com
echo ""

echo "=== USER INFO ==="
id
groups
echo ""

echo "=== SYSTEMD FAILED SERVICES ==="
systemctl --failed
echo ""

echo "=== CLONE SERVICE STATUS ==="
systemctl status clone-config-repo.service --no-pager
echo ""

echo "=== SSH STATUS ==="
systemctl status sshd --no-pager
echo ""

echo "=== NIXOS VERSION ==="
nixos-version
echo ""

echo "=== NIXED REPO ==="
ls -la ~/nixos-config/ 2>/dev/null || echo "Repo not found"
echo ""

echo "=== BOOT ENTRIES ==="
sudo bootctl list
echo ""

echo "=== RECENT ERRORS IN JOURNAL ==="
sudo journalctl -p 3 -b --no-pager | tail -20
echo ""

echo "=== CONFIGURATION TEST ==="
sudo nixos-rebuild dry-build
