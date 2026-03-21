# Session State - March 21, 2026 17:51 UTC

## STATUS: Full pipeline working, ready for final clean test

### What's done:
- Automated Windows install: autounattend.xml + two-phase setup.ps1 on floppy
- Phase 1: SSH, RDP, Choco, Git, WSL features, DISM activation (last)
- Phase 2: SYSTEM AtStartup → Windows Update + WSL 2.6.3 MSI (curl.exe) + Ubuntu WSL2
- Verified: ServerStandard activated, build 20348.4893, WSL2 kernel 6.6.87, Ubuntu v2
- run-windows.sh boots existing VM, SSH works on port 2222 within 60s
- Security group: ports 22, 2222, 3389, 5900 open
- Cloud-init auto-starts Windows VM if QCOW2 exists
- CodeCommit repo pushed with 9 files + comprehensive README

### Bug fixed this session:
- DISM must be LAST in setup.ps1 (forces immediate reboot)
- Phase 2 must be SYSTEM AtStartup (not AtLogOn) to survive DISM reboot
- Use curl.exe not Invoke-WebRequest for WSL MSI download (IWR hangs)

### Instance: terminated (i-029eb9b3cddb94a5f)
### EBS: vol-049250470b06c4ba7 (will auto-detach)

### QCOW2 files on /opt:
- winserver2022-auto.qcow2 (25G) — fully working: activated, WSL2, Ubuntu
- winserver2022-test.qcow2 (11G) — basic install test
- winserver2022-wsl2-ready.qcow2 (25G) — backup

### Tomorrow's test:
1. `bash launch-metal-spot.sh c5.metal` — new instance, cloud-init auto-starts VM
2. `ssh -p 2222 Administrator@<IP>` — should work directly
3. Verify: activation, WSL2, Git, Choco all intact
4. Optional: fresh install test with updated setup.ps1 (curl.exe fix)
