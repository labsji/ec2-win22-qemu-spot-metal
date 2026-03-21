#!/bin/bash
set -euo pipefail

QCOW_PATH="/opt/winserver2022-auto.qcow2"
VIRTIO_ISO="/data/virtio-win.iso"
source /opt/hw-id.conf

[ -f "$QCOW_PATH" ] || { echo "ERROR: $QCOW_PATH not found"; exit 1; }

echo "Starting Windows Server 2022 (VNC :0)..."
sudo nohup qemu-system-x86_64 -enable-kvm -m 16G -smp 8 -cpu host \
  -machine q35 -bios /usr/share/ovmf/OVMF.fd \
  $QEMU_SMBIOS_OPTS \
  -drive file="$QCOW_PATH",format=qcow2,if=virtio \
  -drive file="$VIRTIO_ISO",media=cdrom,index=1 \
  -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -vga qxl -display none -vnc :0 \
  -device usb-ehci -device usb-tablet \
  -monitor unix:/tmp/qemu-mon.sock,server,nowait \
  > /tmp/qemu.log 2>&1 &

sleep 2
pgrep qemu-system-x86 || { echo "QEMU failed to start"; cat /tmp/qemu.log; exit 1; }
echo "QEMU running (PID $(pgrep qemu-system-x86))"
echo "VNC: localhost:5900 | RDP: localhost:3389 | SSH: localhost:2222"
