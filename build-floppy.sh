#!/bin/bash
set -euo pipefail
# Build floppy image with autounattend.xml and setup.ps1
FLOPPY="${1:-/opt/floppy.img}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

dd if=/dev/zero of="$FLOPPY" bs=1M count=3
mkfs.fat "$FLOPPY"
MNTDIR=$(mktemp -d)
sudo mount "$FLOPPY" "$MNTDIR"
sudo cp "$SCRIPT_DIR/autounattend.xml" "$MNTDIR/"
sudo cp "$SCRIPT_DIR/setup.ps1" "$MNTDIR/"
# Use private key if available, otherwise template
if [ -f "$SCRIPT_DIR/secrets/activation-key.txt" ]; then
  sudo cp "$SCRIPT_DIR/secrets/activation-key.txt" "$MNTDIR/"
else
  sudo cp "$SCRIPT_DIR/activation-key.txt" "$MNTDIR/"
fi
sudo umount "$MNTDIR"
rmdir "$MNTDIR"
echo "Floppy image created: $FLOPPY"
