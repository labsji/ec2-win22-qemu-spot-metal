#!/bin/bash
set -euo pipefail
# install-windows.sh <vm-name> - Install Windows Server 2022 on a named VM
# The VM's volume should be mounted at /vm/<name>/
# ISOs should be at /data/

VM_NAME="${1:-ikuku}"
VM_DIR="/vm/$VM_NAME"
QCOW_PATH="$VM_DIR/disk.qcow2"
WIN_ISO="/data/win2022.iso"
VIRTIO_ISO="/data/virtio-win.iso"
FLOPPY="/opt/shazam/floppy.img"
ANSWER_ISO="$VM_DIR/answer.iso"

source /opt/shazam/hw-id.conf 2>/dev/null || true

[ -d "$VM_DIR" ] || { echo "ERROR: $VM_DIR not mounted. Is the volume attached?"; exit 1; }
for f in "$WIN_ISO" "$VIRTIO_ISO" "$FLOPPY"; do
    [ -f "$f" ] || { echo "ERROR: $f not found"; exit 1; }
done

# Convert floppy to ISO (UEFI doesn't support floppy)
if [ ! -f "$ANSWER_ISO" ] || [ "$FLOPPY" -nt "$ANSWER_ISO" ]; then
    echo "Building answer ISO from floppy..."
    TMPDIR=$(mktemp -d)
    mount -o loop "$FLOPPY" "$TMPDIR"
    genisoimage -o "$ANSWER_ISO" -J -r "$TMPDIR" 2>/dev/null || mkisofs -o "$ANSWER_ISO" -J -r "$TMPDIR" 2>/dev/null
    umount "$TMPDIR"
    rmdir "$TMPDIR"
fi

echo "Creating fresh QCOW2 disk for $VM_NAME..."
rm -f "$QCOW_PATH"
qemu-img create -f qcow2 "$QCOW_PATH" 100G

# Find the slot for this VM (port assignment)
SLOT=0
for d in /vm/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "$VM_NAME" ] && break
    SLOT=$((SLOT+1))
done
SSH_PORT=$((2222 + SLOT))
RDP_PORT=$((3389 + SLOT))
VNC_DISPLAY=$SLOT

echo "Starting headless Windows auto-install for $VM_NAME..."
echo "  VNC :$VNC_DISPLAY | SSH :$SSH_PORT | RDP :$RDP_PORT"

nohup qemu-system-x86_64 -enable-kvm -m 16G -smp 8 -cpu host \
    -machine q35 -bios /usr/share/ovmf/OVMF.fd \
    ${QEMU_SMBIOS_OPTS:-} \
    -drive file="$QCOW_PATH",format=qcow2,if=virtio \
    -drive file="$WIN_ISO",media=cdrom,index=0 \
    -drive file="$VIRTIO_ISO",media=cdrom,index=1 \
    -drive file="$ANSWER_ISO",media=cdrom,index=2 \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${RDP_PORT}-:3389 \
    -device virtio-net-pci,netdev=net0 \
    -vga qxl -display none -vnc :${VNC_DISPLAY} \
    -device usb-ehci -device usb-tablet \
    -monitor unix:/tmp/qemu-mon-${VM_NAME}.sock,server,nowait \
    > /tmp/win-install-${VM_NAME}.log 2>&1 &

sleep 2
pgrep qemu-system-x86 || { echo "QEMU failed to start"; cat /tmp/win-install-${VM_NAME}.log; exit 1; }
echo "QEMU running (PID $(pgrep -f "qemu-mon-${VM_NAME}"))"

echo "Sending keystrokes for 'Press any key to boot from CD'..."
for i in $(seq 1 30); do
    echo "sendkey ret" | socat - UNIX-CONNECT:/tmp/qemu-mon-${VM_NAME}.sock > /dev/null 2>&1 || true
    sleep 1
done

echo ""
echo "Windows installing in background (~30 min)."
echo "Monitor: tail -f /tmp/win-install-${VM_NAME}.log"
echo "After install: bash shazam.sh snapshot $VM_NAME"
