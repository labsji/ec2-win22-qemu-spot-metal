#!/bin/bash
# test-and-terminate.sh — unattended schtasks test on existing spot instance
# Run in tmux/screen: tmux new -d -s test 'bash test-and-terminate.sh'
set -euo pipefail

IP=13.126.177.224
KEY=~/.ssh/ett8u-key
LOG=~/metal-spot4win/test-log-$(date +%Y%m%d-%H%M).txt
WINSSH="sshpass -p Admin2026 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -p 2222 Administrator@localhost"

exec > >(tee -a "$LOG") 2>&1
echo "=== Test started $(date) ==="

# Wait for HTTP 200 (Frappe init in progress)
echo "Waiting for HTTP 200 at /lms..."
for i in $(seq 1 60); do
    CODE=$(ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/lms 2>/dev/null\\\"\"" 2>/dev/null || echo "000")
    echo "  attempt $i: HTTP $CODE"
    [ "$CODE" = "200" ] && break
    sleep 30
done

if [ "$CODE" != "200" ]; then
    echo "FAIL: Never got HTTP 200. Checking logs..."
    ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"podman logs --tail 20 lms_frappe_1 2>&1\\\"\"" 2>/dev/null || true
    echo "=== Terminating instance ==="
    aws ec2 terminate-instances --region ap-south-1 --instance-ids i-09cd142cfaa5dd507 --output text
    echo "=== FAILED $(date) ==="
    exit 1
fi

echo "=== HTTP 200 confirmed. Rebooting Windows... ==="
ssh -i $KEY ubuntu@$IP "$WINSSH \"shutdown /r /t 0\"" 2>/dev/null || true

echo "Waiting 120s for reboot..."
sleep 120

# Wait for SSH after reboot
echo "Waiting for Windows SSH..."
for i in $(seq 1 20); do
    ssh -i $KEY ubuntu@$IP "$WINSSH \"hostname\"" 2>/dev/null && break
    sleep 15
done

# Check task is running after reboot
echo "Checking scheduled task..."
ssh -i $KEY ubuntu@$IP "$WINSSH \"powershell -Command \\\"(Get-ScheduledTask -TaskName FrappeLMS).State\\\"\"" 2>/dev/null || echo "TASK CHECK FAILED"

# Wait for containers after reboot
echo "Waiting for containers..."
sleep 60
ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- podman ps --format \\\"{{.Names}} {{.Status}}\\\"\"" 2>/dev/null || echo "CONTAINER CHECK FAILED"

# Wait for HTTP 200 after reboot
echo "Waiting for HTTP 200 after reboot..."
for i in $(seq 1 60); do
    CODE=$(ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/lms 2>/dev/null\\\"\"" 2>/dev/null || echo "000")
    echo "  attempt $i: HTTP $CODE"
    [ "$CODE" = "200" ] && break
    sleep 30
done

echo ""
if [ "$CODE" = "200" ]; then
    echo "=== PASS: schtasks S4U survived reboot, HTTP 200 at /lms ==="
else
    echo "=== FAIL: HTTP $CODE after reboot ==="
    ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"podman logs --tail 20 lms_frappe_1 2>&1\\\"\"" 2>/dev/null || true
fi

# Save snapshot and terminate
echo "Saving snapshot..."
ssh -i $KEY ubuntu@$IP 'echo "savevm schtasks-tested-2026-03-27" | sudo socat - UNIX-CONNECT:/tmp/qemu-mon.sock' 2>/dev/null || true
sleep 20

echo "Terminating instance..."
aws ec2 terminate-instances --region ap-south-1 --instance-ids i-09cd142cfaa5dd507 --output text

echo "=== Done $(date) ==="
