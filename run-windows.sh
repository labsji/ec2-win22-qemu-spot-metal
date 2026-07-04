#!/bin/bash
set -euo pipefail
# run-windows.sh [vm-name] - Start a Windows VM from its QCOW2 disk
# If no name given, starts all VMs found in /vm/*/

VM_NAME="${1:-}"
VIRTIO_ISO="/data/virtio-win.iso"

source /opt/shazam/hw-id.conf 2>/dev/null || true

start_vm() {
    local name="$1" slot="$2"
    local vmdir="/vm/$name"
    local qcow="$vmdir/disk.qcow2"

    [ -f "$qcow" ] || { echo "SKIP $name: no disk.qcow2"; return; }

    # Don't start if already running
    [ -S "/tmp/qemu-mon-${name}.sock" ] && pgrep -f "qemu-mon-${name}" >/dev/null && {
        echo "SKIP $name: already running"
        return
    }

    local ssh_port=$((2222 + slot))
    local rdp_port=$((3389 + slot))
    local vnc_display=$slot

    echo "Starting $name (SSH:$ssh_port RDP:$rdp_port VNC:$vnc_display)..."
    nohup qemu-system-x86_64 -enable-kvm -m 16G -smp 8 -cpu host \
        -machine q35 -bios /usr/share/ovmf/OVMF.fd \
        ${QEMU_SMBIOS_OPTS:-} \
        -drive file="$qcow",format=qcow2,if=virtio \
        ${VIRTIO_ISO:+-drive file=$VIRTIO_ISO,media=cdrom,index=1} \
        -netdev user,id=net0,hostfwd=tcp::${ssh_port}-:22,hostfwd=tcp::${rdp_port}-:3389 \
        -device virtio-net-pci,netdev=net0 \
        -vga qxl -display none -vnc :${vnc_display} \
        -device usb-ehci -device usb-tablet \
        -monitor unix:/tmp/qemu-mon-${name}.sock,server,nowait \
        > /tmp/qemu-${name}.log 2>&1 &

    sleep 2
    pgrep -f "qemu-mon-${name}" >/dev/null && echo "  ✓ $name running" || echo "  ✗ $name failed (see /tmp/qemu-${name}.log)"
}

if [ -n "$VM_NAME" ]; then
    start_vm "$VM_NAME" 0
else
    # Start all VMs
    SLOT=0
    for vmdir in /vm/*/; do
        [ -d "$vmdir" ] || continue
        name=$(basename "$vmdir")
        start_vm "$name" $SLOT
        SLOT=$((SLOT+1))
    done
fi
