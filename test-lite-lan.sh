#!/bin/bash
# test-lite-lan.sh — Install ikuku-lite on running metal spot, test HTTP, terminate
set -euo pipefail

RELEASE="v0.1.7"
APPS="wiki"
LOG="$HOME/metal-spot4win/lite-test-$(date +%Y%m%d-%H%M).txt"
WINPASS="Admin2026"
TIMEOUT_HTTP=600

cd ~/metal-spot4win
IP=$(cat .instance-ip)
KEY=$(ls ~/.ssh/shazam-* 2>/dev/null | grep -v pub | head -1)

exec > >(tee -a "$LOG") 2>&1
echo "=== ikuku lite LAN test — $RELEASE — $(date) ==="
echo "IP: $IP"

WINSSH="sshpass -p $WINPASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 2222 Administrator@$IP"

# 1. Wait for Windows SSH
echo "--- Waiting for Windows SSH ---"
for i in $(seq 1 120); do
    if $WINSSH "echo winready" 2>/dev/null | grep -q winready; then
        echo "Windows SSH ready after $((i*10))s"
        break
    fi
    [ $i -eq 120 ] && { echo "FAIL: Windows SSH timeout (20min)"; bash shazam.sh down; exit 1; }
    sleep 10
done

# 2. Clean previous install
echo "--- Cleaning previous install ---"
$WINSSH "wsl -u root -- bash -c 'podman rm -af 2>/dev/null; podman rmi -af 2>/dev/null; rm -rf /opt/ikuku' || true" 2>&1
$WINSSH "powershell -Command \"Remove-Item 'C:\\Program Files\\ikuku' -Recurse -Force -ErrorAction SilentlyContinue\"" 2>&1 || true

# 3. Download lite exe
echo "--- Downloading ikuku-lite.exe ---"
$WINSSH "powershell -Command \"Invoke-WebRequest -Uri 'https://github.com/labsji/ikuku/releases/download/$RELEASE/ikuku-lite.exe' -OutFile C:\\Users\\Administrator\\ikuku-lite.exe\"" 2>&1
$WINSSH "dir C:\\Users\\Administrator\\ikuku-lite.exe" 2>&1

# 4. Run installer (silent mode uses default app: wiki)
echo "--- Running installer ---"
$WINSSH "powershell -Command \"Start-Process C:\\Users\\Administrator\\ikuku-lite.exe -ArgumentList '/S' -Wait\"" 2>&1
echo "Installer finished at $(date)"

# 5. Check install state
echo "--- Checking install state ---"
$WINSSH "wsl -u root -- ls -la /opt/ikuku/" 2>&1 || echo "WARN: /opt/ikuku not found"
$WINSSH "wsl -u root -- cat /opt/ikuku/.env" 2>&1 || echo "WARN: .env not found"
$WINSSH "wsl -u root -- podman ps -a" 2>&1

# 6. Wait for HTTP 200
echo "--- Waiting for HTTP ---"
START=$SECONDS
while [ $((SECONDS - START)) -lt $TIMEOUT_HTTP ]; do
    STATUS=$($WINSSH "powershell -Command \"try { (Invoke-WebRequest -Uri http://localhost:8000 -UseBasicParsing -TimeoutSec 5).StatusCode } catch { 0 }\"" 2>/dev/null | tr -d '\r\n' || echo "0")
    echo "  $(date +%H:%M:%S) status=$STATUS"
    [ "$STATUS" = "200" ] && { echo "HTTP 200 after $((SECONDS - START))s"; break; }
    sleep 30
done

# 7. Test endpoints
echo "--- Testing endpoints ---"
PASS=0; FAIL=0
for path in "/" "/wiki/"; do
    STATUS=$($WINSSH "powershell -Command \"try { (Invoke-WebRequest -Uri http://localhost:8000${path} -UseBasicParsing -TimeoutSec 10).StatusCode } catch { 0 }\"" 2>/dev/null | tr -d '\r\n' || echo "0")
    echo "  http://localhost:8000${path} => $STATUS"
    [ "$STATUS" = "200" ] && ((PASS++)) || ((FAIL++))
done

# 8. List apps
echo "--- Installed apps ---"
$WINSSH "wsl -u root -- bash -c 'cd /opt/ikuku && podman-compose exec -T frappe bench --site all list-apps'" 2>&1 || true

# 9. Results
echo ""
echo "=== RESULTS ==="
echo "Pass: $PASS  Fail: $FAIL"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"

# 10. Terminate
echo "--- Terminating ---"
cd ~/metal-spot4win && bash shazam.sh down 2>&1
echo "=== Done — $(date) ==="
