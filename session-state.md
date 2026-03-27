# Session Summary — 2026-03-24

## What was accomplished

### Non-admin user test ✅
- Evaluator (evaluator/Eval2026!) gets HTTP 200 at `/lms` — can browse LMS without admin rights
- Install requires admin (NSSM, firewall, choco) — expected, NSIS enforces UAC
- WSL distros are per-user — service must run under admin account via NSSM ObjectName

### Regression test (ikuku rename) ✅
- FrappeLMS service name works
- lms-service.ps1 starts containers, waits for systemd, refreshes port proxy
- Confirmed on c5n.metal spot instance

### GitHub Actions workflow fixed
- Changed from release trigger (caused email spam) to workflow_dispatch + push on feature branch
- Lite .exe builds successfully (93.6KB) on windows-latest runner
- Artifact downloadable as zip from Actions tab

### Bug found: init.sh on EBS volume
- Old init.sh (without --resolve-deps) was baked into /opt/frappe-lms/ on the EBS volume
- Fresh installs via install.ps1 copy docker/ dir from repo → correct init.sh deployed
- Only affects snapshot restore scenarios — fixed in-place with sed

## Current state

### Git
- Branch: labsji/frappe-lms:breeze-windows-installer-clean
- Last commit: 677b98b8 (workflow fix)
- 11 commits ahead of origin/develop
- Push via: GIT_SSH_COMMAND="ssh -i ~/.ssh/dspace-dev-key.pem" git push origin breeze-windows-installer-clean

### EBS volume (vol-049250470b06c4ba7, ap-south-1a)
- Snapshots inside winserver2022-auto.qcow2:
  - lms-working-2026-03-23 — pre-refactor (BreezeLMS service, C:\breeze\)
  - ikuku-tested-2026-03-24 — post-refactor (FrappeLMS service, C:\FrappeLMS\), evaluator tested
- /opt/frappe-lms/init.sh patched with --resolve-deps (in ikuku-tested snapshot)

### Instance: terminated

## Remaining work
1. De-AI and humanize scripts for PR readiness
2. Build full (offline) installer — needs pre-built container image with frappe+payments+lms baked in
3. Add WIN_PASSWORD to NSIS wizard or find passwordless NSSM approach
4. Sample LMS course content (next iteration)
5. Update launch-metal-spot.sh to not hardcode volume ID
