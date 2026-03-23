# Session State - March 22, 2026 18:05 UTC

## Key Discovery: WSL Container Lifecycle Issue

Containers kept dying because WSL shuts down when no foreground session exists.
- `podman-compose up -d` starts containers, SSH session ends, WSL shuts down, containers die
- Fix found: keep a background WSL process alive via `Start-Process wsl.exe -WindowStyle Hidden`
- With background process: all 3 containers (MariaDB, Redis, Frappe) stayed up for 5+ min ✓
- systemd=true in wsl.conf doesn't work on Server 2022 WSL
- Frappe init.sh takes ~10 min (git clone, pip install, bench build)
- WSL needs 12GB RAM (.wslconfig) for Frappe build

## Breeze Installer Status
- install.ps1 flow validated on both WSL1 (winkino) and WSL2 (metal spot) ✓
- NSIS lite exe builds (92KB) ✓
- Non-admin user created (evaluator/Eval2026!) ✓
- Containers start and stay running with background WSL process ✓
- HTTP 200 confirmed earlier when Frappe fully initialized ✓

## TODO for install.ps1
- Add .wslconfig setup (memory=12GB, swap=4GB)
- Add wsl.conf setup (systemd=true, though it doesn't work on Server 2022)
- Add background WSL keepalive process in start.ps1
- The start.ps1 scheduled task (AtStartup as SYSTEM) needs to keep WSL alive
- Test full Frappe init to HTTP 200 in one session

## Repos
- metal-spot4win: GitHub + CodeCommit, all committed
- frappe-lms: branch breeze-windows-installer-clean, all committed
