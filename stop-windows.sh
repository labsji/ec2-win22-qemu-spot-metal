#!/bin/bash
# stop-windows.sh [vm-name] - Gracefully stop Windows VM(s)
# If no name given, stops all running VMs.

VM_NAME="${1:-}"

stop_vm() {
    local name="$1"
    local sock="/tmp/qemu-mon-${name}.sock"
    if [ -S "$sock" ]; then
        echo "Stopping $name (ACPI shutdown)..."
        echo "system_powerdown" | socat - UNIX-CONNECT:"$sock" 2>/dev/null || true
        # Wait up to 30s for graceful shutdown
        for i in $(seq 1 30); do
            pgrep -f "qemu-mon-${name}" >/dev/null || { echo "  ✓ $name stopped"; return; }
            sleep 1
        done
        echo "  ⚠ $name didn't stop gracefully, killing..."
        pkill -f "qemu-mon-${name}" 2>/dev/null || true
    else
        echo "  $name not running"
    fi
}

if [ -n "$VM_NAME" ]; then
    stop_vm "$VM_NAME"
else
    for sock in /tmp/qemu-mon-*.sock; do
        [ -S "$sock" ] || continue
        name=$(basename "$sock" | sed 's/qemu-mon-//;s/.sock//')
        stop_vm "$name"
    done
fi
