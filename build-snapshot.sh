#!/bin/bash
# build-snapshot.sh — Wait for Windows install, setup WSL2, snapshot EBS
set -euo pipefail

IP=65.2.191.123
INSTANCE_ID=i-012f2f9e708c148d5
VOL_ID=vol-0487e96779caa9677
KEY=$(ls ~/.ssh/shazam-* 2>/dev/null | grep -v pub | head -1)
WINPASS="Admin2026"
REGION=ap-south-1

echo "=== Building shazam snapshot — $(date) ==="

# 1. Wait for Windows SSH (port 2222)
echo "--- Waiting for Windows install + SSH (up to 40 min) ---"
for i in $(seq 1 240); do
    if sshpass -p "$WINPASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 2222 Administrator@$IP "echo winready" 2>/dev/null | grep -q winready; then
        echo "Windows SSH ready after $((i*10))s"
        break
    fi
    if [ $((i % 6)) -eq 0 ]; then
        SIZE=$(ssh -o StrictHostKeyChecking=no -i $KEY ubuntu@$IP "ls -lh /opt/winserver2022-auto.qcow2 2>/dev/null | awk '{print \$5}'" 2>/dev/null)
        echo "  $((i*10))s — QCOW2 size: $SIZE"
    fi
    [ $i -eq 240 ] && { echo "FAIL: Windows SSH timeout (40min)"; exit 1; }
    sleep 10
done

WINSSH="sshpass -p $WINPASS ssh -o StrictHostKeyChecking=no -p 2222 Administrator@$IP"

# 2. Wait for setup.ps1 to finish (reboots happen)
echo "--- Waiting for post-install setup ---"
sleep 60
for i in $(seq 1 30); do
    if $WINSSH "echo ready" 2>/dev/null | grep -q ready; then
        echo "Windows stable after reboot"
        break
    fi
    sleep 20
done

# 3. Check WSL2
echo "--- Checking WSL2 ---"
$WINSSH "wsl --status" 2>&1 || echo "WSL not ready yet"
$WINSSH "wsl -l -v" 2>&1 || echo "No distros"

# 4. If WSL2 + Ubuntu not installed, install them
echo "--- Ensuring WSL2 + Ubuntu ---"
WSL_CHECK=$($WINSSH "wsl -l -q 2>&1" 2>/dev/null | tr -d '\0\r' || echo "")
if echo "$WSL_CHECK" | grep -qi ubuntu; then
    echo "Ubuntu already installed"
else
    echo "Installing WSL2 + Ubuntu..."
    $WINSSH "wsl --install Ubuntu --no-launch" 2>&1 || true
    sleep 30
    # May need reboot
    $WINSSH "shutdown /r /t 5 /f" 2>&1 || true
    echo "Rebooting for WSL2..."
    sleep 120
    for i in $(seq 1 30); do
        $WINSSH "echo ready" 2>/dev/null && break
        sleep 10
    done
    # Complete Ubuntu setup
    $WINSSH "ubuntu install --root" 2>&1 || true
fi

# 5. Install podman in WSL
echo "--- Installing podman ---"
$WINSSH "wsl -u root -- bash -c 'which podman || (apt-get update -qq && apt-get install -y -qq podman podman-compose && sed -i \"/^unqualified-search-registries/d\" /etc/containers/registries.conf && echo \"unqualified-search-registries = [\\\"docker.io\\\"]\" >> /etc/containers/registries.conf)'" 2>&1 || echo "podman install issue"

# 6. Verify
echo "--- Verification ---"
$WINSSH "wsl -u root -- podman --version" 2>&1
$WINSSH "wsl -u root -- podman run --rm alpine echo ok" 2>&1

# 7. Shut down Windows cleanly
echo "--- Shutting down Windows ---"
$WINSSH "shutdown /s /t 5 /f" 2>&1 || true
sleep 30

# Wait for QEMU to stop
ssh -i $KEY ubuntu@$IP "for i in \$(seq 1 30); do pgrep qemu-system-x86 || break; sleep 5; done; echo 'QEMU stopped'" 2>&1

# 8. Snapshot the EBS volume
echo "--- Creating EBS snapshot ---"
SNAP_ID=$(aws ec2 create-snapshot --region $REGION --volume-id $VOL_ID \
    --description "shazam: Windows Server 2022 eval + WSL2 + podman" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=shazam-ready}]" \
    --query 'SnapshotId' --output text)
echo "Snapshot: $SNAP_ID"

echo "--- Waiting for snapshot to complete ---"
aws ec2 wait snapshot-completed --region $REGION --snapshot-ids $SNAP_ID
echo "Snapshot $SNAP_ID complete!"

# 9. Terminate instance
echo "--- Terminating instance ---"
cd ~/metal-spot4win && bash shazam.sh down 2>&1

echo ""
echo "=== DONE ==="
echo "Snapshot ID: $SNAP_ID"
echo "Add this to shazam.sh: SNAPSHOT_ID=\"$SNAP_ID\""
echo "$(date)"
