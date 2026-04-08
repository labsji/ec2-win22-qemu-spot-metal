#!/bin/bash
# test-full-exe.sh — Download full.zip, install on Windows, verify Wiki HTTP 200, terminate
set -euo pipefail
IP=13.126.174.202
KEY=~/.ssh/ett8u-key
LOG=~/metal-spot4win/test-full-$(date +%Y%m%d-%H%M).txt
WINSSH="sshpass -p Admin2026 ssh -o StrictHostKeyChecking=no -p 2222 Administrator@localhost"

exec > >(tee "$LOG") 2>&1
echo "=== Started $(date) ==="

# Step 1: Download full.zip on Linux host
echo "Downloading full.zip on Linux host..."
ssh -i $KEY ubuntu@$IP 'wget -q -O /tmp/ikuku-full.zip https://github.com/labsji/ikuku/releases/download/v0.1.0/ikuku-full.zip'
ssh -i $KEY ubuntu@$IP 'ls -lh /tmp/ikuku-full.zip'

# Step 2: Copy to Windows via SCP
echo "Copying to Windows..."
ssh -i $KEY ubuntu@$IP "sshpass -p Admin2026 scp -o StrictHostKeyChecking=no -P 2222 /tmp/ikuku-full.zip Administrator@localhost:C:/Users/Administrator/Desktop/ikuku-full.zip"
echo "Copy done"

# Step 3: Unzip on Windows
echo "Unzipping..."
ssh -i $KEY ubuntu@$IP "$WINSSH \"powershell -Command \\\"Expand-Archive -Path C:\\Users\\Administrator\\Desktop\\ikuku-full.zip -DestinationPath C:\\Users\\Administrator\\Desktop\\ikuku-full -Force\\\"\""
ssh -i $KEY ubuntu@$IP "$WINSSH \"dir C:\\Users\\Administrator\\Desktop\\ikuku-full\""

# Step 4: Run the NSIS installer silently
echo "Running installer..."
ssh -i $KEY ubuntu@$IP "$WINSSH \"C:\\Users\\Administrator\\Desktop\\ikuku-full\\ikuku-full.exe /S /D=C:\\Program Files\\ikuku\""
sleep 5

# Step 5: Copy fixed install.ps1 (with PS5.1 + CRLF fixes)
echo "Copying fixed install.ps1..."
scp -i $KEY ~/ikuku/install.ps1 ubuntu@$IP:/tmp/install.ps1
ssh -i $KEY ubuntu@$IP "sshpass -p Admin2026 scp -o StrictHostKeyChecking=no -P 2222 /tmp/install.ps1 'Administrator@localhost:C:/Program Files/ikuku/install.ps1'"

# Step 6: Run install with wiki
echo "Running install.ps1 -Apps wiki..."
ssh -i $KEY ubuntu@$IP "$WINSSH \"powershell -ExecutionPolicy Bypass -File \\\"C:\\Program Files\\ikuku\\install.ps1\\\" -Apps wiki\""

# Step 7: Wait for Frappe to start (up to 15 min)
echo "Waiting for HTTP 200 on /wiki/..."
for i in $(seq 1 45); do
    sleep 20
    CODE=$(ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/wiki/ 2>/dev/null\\\"\"" 2>/dev/null || echo "000")
    echo "  Attempt $i: HTTP $CODE"
    if [ "$CODE" = "200" ]; then
        echo "=== WIKI TEST PASSED ==="
        break
    fi
done

if [ "$CODE" != "200" ]; then
    echo "=== WIKI TEST FAILED ==="
    echo "Container logs:"
    ssh -i $KEY ubuntu@$IP "$WINSSH \"wsl -u root -- bash -c \\\"podman logs --tail 30 ikuku_frappe_1 2>&1\\\"\"" || true
fi

# Step 8: Check if bundle was used (offline mode)
echo "Checking if bundle was detected..."
ssh -i $KEY ubuntu@$IP "$WINSSH \"dir \\\"C:\\Program Files\\ikuku\\bundle\\\" 2>&1\"" || echo "No bundle dir found"

echo "=== Finished $(date) ==="
echo "Log: $LOG"

# Step 9: Terminate instance
echo "Terminating instance i-0bac365513addb688..."
aws ec2 terminate-instances --region ap-south-1 --instance-ids i-0bac365513addb688 --query 'TerminatingInstances[0].CurrentState.Name' --output text
echo "=== Instance terminated ==="
