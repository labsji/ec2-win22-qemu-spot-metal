#!/bin/bash
echo "Sending ACPI shutdown..."
echo "system_powerdown" | sudo socat - UNIX-CONNECT:/tmp/qemu-mon.sock
for i in $(seq 1 30); do
  pgrep qemu-system-x86 > /dev/null || { echo "QEMU stopped."; exit 0; }
  sleep 1
done
echo "Still running after 30s, forcing quit..."
echo "quit" | sudo socat - UNIX-CONNECT:/tmp/qemu-mon.sock
sleep 2
pgrep qemu-system-x86 > /dev/null && sudo kill $(pgrep qemu-system-x86)
echo "Done."
