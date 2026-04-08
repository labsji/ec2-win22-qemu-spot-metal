#!/bin/bash
set -euo pipefail
IP=43.205.120.125
KEY=~/.ssh/ett8u-key
INST=i-0e140a11f06890cb8
LOG=~/metal-spot4win/full-test-$(date +%Y%m%d-%H%M).txt
SSH="sshpass -p Admin2026 ssh -o StrictHostKeyChecking=no -p 2222 Administrator@localhost"
RSSH="ssh -o StrictHostKeyChecking=no -i $KEY ubuntu@$IP"

exec > >(tee "$LOG") 2>&1
echo "=== Full.exe test started $(date) ==="

# Wait for bench start (up to 30 min)
for i in $(seq 1 60); do
  TAIL=$($RSSH "$SSH \"wsl -u root -- bash -c 'podman logs --tail 3 ikuku_frappe_1 2>&1'\"" 2>&1 || true)
  echo "[$i] $(date +%H:%M:%S) $TAIL"
  if echo "$TAIL" | grep -q "Running on"; then
    echo "=== Frappe is up ==="
    break
  fi
  sleep 30
done

# Test HTTP endpoints
sleep 10
for route in "/" "/wiki/" "/lms"; do
  CODE=$($RSSH "$SSH \"wsl -u root -- bash -c \\\"curl -s -o /dev/null -w '%{http_code}' http://localhost:8000${route} 2>/dev/null\\\"\"" 2>&1 || echo "FAIL")
  echo "HTTP $route => $CODE"
done

# Check installed apps
APPS=$($RSSH "$SSH \"wsl -u root -- bash -c 'podman exec ikuku_frappe_1 bash -c \\\"cd frappe-bench && bench --site ikuku.localhost list-apps 2>/dev/null\\\"'\"" 2>&1 || echo "FAIL")
echo "Installed apps: $APPS"

echo "=== Test complete $(date) ==="

# Terminate
echo "Terminating $INST..."
aws ec2 terminate-instances --region ap-south-1 --instance-ids $INST --query 'TerminatingInstances[0].CurrentState.Name' --output text
echo "Done."
