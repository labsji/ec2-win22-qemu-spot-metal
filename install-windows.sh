#!/bin/bash
set -euo pipefail

QCOW_PATH="/opt/winserver2022-auto.qcow2"
WIN_ISO="/data/win2022.iso"
VIRTIO_ISO="/data/virtio-win.iso"
FLOPPY="/opt/floppy.img"
source /opt/hw-id.conf

for f in "$WIN_ISO" "$VIRTIO_ISO" "$FLOPPY"; do
  [ -f "$f" ] || { echo "ERROR: $f not found"; exit 1; }
done

echo "Creating fresh QCOW2 disk..."
rm -f "$QCOW_PATH"
qemu-img create -f qcow2 "$QCOW_PATH" 100G

echo "Starting headless Windows auto-install (VNC :0)..."
sudo nohup qemu-system-x86_64 -enable-kvm -m 16G -smp 8 -cpu host \
  -machine q35 -bios /usr/share/ovmf/OVMF.fd \
  $QEMU_SMBIOS_OPTS \
  -drive file="$QCOW_PATH",format=qcow2,if=virtio \
  -drive file="$WIN_ISO",media=cdrom,index=0 \
  -drive file="$VIRTIO_ISO",media=cdrom,index=1 \
  -fda "$FLOPPY" \
  -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -vga qxl -display none -vnc :0 \
  -device usb-ehci -device usb-tablet \
  -monitor unix:/tmp/qemu-mon.sock,server,nowait \
  > /tmp/qemu.log 2>&1 &

sleep 2
pgrep qemu-system-x86 || { echo "QEMU failed to start"; cat /tmp/qemu.log; exit 1; }
echo "QEMU running (PID $(pgrep qemu-system-x86))"

echo "Sending keystrokes for 'Press any key to boot from CD'..."
for i in $(seq 1 30); do
  echo "sendkey ret" | sudo socat - UNIX-CONNECT:/tmp/qemu-mon.sock > /dev/null 2>&1
  sleep 1
done

echo "Install started. Monitor with:"
echo "  ls -lh $QCOW_PATH   # should grow to ~8-11GB"
echo "  ~/.local/bin/vncdo -s localhost::5900 capture /tmp/screen.png"
