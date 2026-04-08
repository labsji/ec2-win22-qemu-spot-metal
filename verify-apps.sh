#!/bin/bash
# verify-apps.sh — Launch spot, restore snapshot, verify Wiki+LMS, terminate
set -euo pipefail
LOG=~/metal-spot4win/verify-apps-$(date +%Y%m%d-%H%M).txt
exec > >(tee -a "$LOG") 2>&1
echo "=== Started $(date) ==="

cd ~/metal-spot4win
KEY=~/.ssh/ett8u-key
WINSSH='sshpass -p "Admin2026" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -p 2222 Administrator@localhost'

# Launch
echo "Launching spot instance..."
bash launch-metal-spot.sh c5n.metal 2>&1 || bash launch-metal-spot.sh c5.metal 2>&1
IP=$(cat .instance-ip)
INST=$(cat .instance-id)
echo "Instance: $INST at $IP"

# Restore snapshot
echo "Restoring wiki-tested-2026-04-02 snapshot..."
ssh -o StrictHostKeyChecking=no -i $KEY ubuntu@$IP 'echo "loadvm wiki-tested-2026-04-02" | sudo socat - UNIX-CONNECT:/tmp/qemu-mon.sock; sleep 3; echo "cont" | sudo socat - UNIX-CONNECT:/tmp/qemu-mon.sock'

# Wait for Windows SSH
echo "Waiting for Windows..."
for i in $(seq 1 20); do
    ssh -i $KEY ubuntu@$IP "$WINSSH hostname" 2>/dev/null && break
    sleep 15
done

# Add port forwarding
ssh -i $KEY ubuntu@$IP 'echo "hostfwd_add tcp::8000-:8000" | sudo socat - UNIX-CONNECT:/tmp/qemu-mon.sock' 2>/dev/null

# Check what's installed
echo "=== Checking installed apps ==="
ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"podman ps --format '{{.Names}} {{.Status}}'\\\"\"" 2>/dev/null || echo "CONTAINERS: FAILED"
ssh -i $KEY ubuntu@$IP "$WINSSH \"dir C:\\\\ikuku 2>nul && dir \\\"C:\\\\Program Files\\\\ikuku\\\" 2>nul && dir \\\"C:\\\\Program Files (x86)\\\\ikuku\\\" 2>nul\"" 2>/dev/null || echo "INSTALL DIR: NOT FOUND"

# Check scheduled task
echo "=== Checking scheduled task ==="
ssh -i $KEY ubuntu@$IP "$WINSSH \"schtasks /query /tn ikuku /v /fo list 2>nul | findstr /C:\\\"Status\\\" /C:\\\"Last Result\\\"\"" 2>/dev/null || echo "TASK: NOT FOUND"

# Wait for HTTP 200 on /wiki/ and /lms
echo "=== Waiting for HTTP 200 ==="
for route in "/wiki/" "/lms"; do
    echo "Testing $route..."
    OK=false
    for i in $(seq 1 40); do
        CODE=$(ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"curl -s -o /dev/null -w '%{http_code}' http://localhost:8000${route} 2>/dev/null\\\"\"" 2>/dev/null || echo "000")
        echo "  attempt $i: HTTP $CODE"
        if [ "$CODE" = "200" ]; then OK=true; break; fi
        sleep 30
    done
    if $OK; then
        echo "PASS: $route HTTP 200"
    else
        echo "FAIL: $route never got HTTP 200"
    fi
done

# Terminate
echo "=== Terminating ==="
aws ec2 terminate-instances --region ap-south-1 --instance-ids $INST --output text
echo "=== Done $(date) ==="
