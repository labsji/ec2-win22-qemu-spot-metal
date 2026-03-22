#!/bin/bash
set -euo pipefail
# Build floppy image with autounattend.xml, setup.ps1, and secrets
FLOPPY="${1:-/opt/floppy.img}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve secrets
if [ -f "$SCRIPT_DIR/secrets/admin-password.txt" ]; then
  PASSWORD=$(cat "$SCRIPT_DIR/secrets/admin-password.txt" | tr -d '\n\r')
  ACTKEY=$(cat "$SCRIPT_DIR/secrets/activation-key.txt" | tr -d '\n\r')
else
  PASSWORD=$(cat "$SCRIPT_DIR/admin-password.txt" | tr -d '\n\r')
  ACTKEY=$(cat "$SCRIPT_DIR/activation-key.txt" | tr -d '\n\r')
fi

# Generate autounattend.xml with secrets injected
sed "s/@@ADMIN_PASSWORD@@/$PASSWORD/g" "$SCRIPT_DIR/autounattend.xml" > /tmp/autounattend.xml

dd if=/dev/zero of="$FLOPPY" bs=1M count=3
mkfs.fat "$FLOPPY"
MNTDIR=$(mktemp -d)
sudo mount "$FLOPPY" "$MNTDIR"
sudo cp /tmp/autounattend.xml "$MNTDIR/"
sudo cp "$SCRIPT_DIR/setup.ps1" "$MNTDIR/"
echo "$ACTKEY" | sudo tee "$MNTDIR/activation-key.txt" > /dev/null
sudo cp "$SCRIPT_DIR/wsl-cloud-init.yaml" "$MNTDIR/"
sudo umount "$MNTDIR"
rmdir "$MNTDIR"
rm -f /tmp/autounattend.xml
echo "Floppy image created: $FLOPPY"
