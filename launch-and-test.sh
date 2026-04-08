#!/bin/bash
# launch-and-test.sh — Retry shazam until quota frees, then run lite test
set -euo pipefail
cd ~/metal-spot4win

echo "=== Waiting for spot capacity — $(date) ==="
for i in $(seq 1 40); do
    echo "Attempt $i at $(date)"
    OUTPUT=$(bash shazam.sh 2>&1) || true
    echo "$OUTPUT" | tail -3
    if echo "$OUTPUT" | grep -qE "Ready|✅|cloud-init"; then
        echo "Launched!"
        # Update IP from actual running instance
        IP=$(aws ec2 describe-instances --region ap-south-1 --filters "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)
        ID=$(aws ec2 describe-instances --region ap-south-1 --filters "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
        [ -n "$IP" ] && echo "$IP" > .instance-ip
        [ -n "$ID" ] && echo "$ID" > .instance-id
        echo "IP: $IP  ID: $ID"
        break
    fi
    [ $i -eq 40 ] && { echo "FAIL: Could not launch after 40 attempts"; exit 1; }
    sleep 60
done

echo "=== Running lite test ==="
bash ~/metal-spot4win/test-lite-lan.sh
