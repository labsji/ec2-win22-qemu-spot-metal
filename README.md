# metal-spot4win

Windows Server 2022 QEMU/KVM dev environment on AWS Linux metal spot instances with WSL2 Ubuntu — for packaging Linux open source software for the Windows ecosystem.

## Quick Start (5 minutes)

### 1. Open AWS CloudShell

Log into the [AWS Console](https://console.aws.amazon.com), then click the CloudShell icon in the top navigation bar:

![Click the CloudShell icon in the AWS Console top bar](.github/cloudshell-icon.svg)

> CloudShell gives you a terminal with AWS credentials already configured — no setup needed.

### 2. Clone and launch

```bash
git clone https://github.com/labsji/ec2-win22-qemu-spot-metal.git
cd ec2-win22-qemu-spot-metal
bash shazam.sh
```

That's it. In ~5 minutes you'll have a Windows Server 2022 VM with WSL2 Ubuntu, SSH, RDP, Git, Chocolatey, and podman.

### 3. When you're done

```bash
bash shazam.sh down      # stop instance, keep your data (~$20/month for EBS)
bash shazam.sh destroy   # delete EVERYTHING, zero ongoing cost
```

### All commands

| Command | What it does |
|---------|-------------|
| `bash shazam.sh` | Launch (or resume) the dev environment |
| `bash shazam.sh down` | Terminate instance, keep EBS data |
| `bash shazam.sh destroy` | Delete ALL resources (confirms first) |
| `bash shazam.sh ssh` | SSH into the Linux host |
| `bash shazam.sh winssh` | SSH into the Windows VM |
| `bash shazam.sh status` | Show current state |
| `bash shazam.sh cost` | Show running costs |

## Why?

**Why metal instances?** Regular EC2 instances run inside a hypervisor — you can't run another hypervisor (QEMU/KVM) inside them. Metal instances give you bare-metal access with hardware virtualization (VT-x), so QEMU can run a Windows VM with near-native performance.

**Why Linux hosting Windows?** AWS Windows metal instances (`i3en.metal`) cost ~$5/hr. Linux metal spot instances (`c5.metal`) cost ~$1.50/hr — 70% cheaper. Running Windows as a QEMU/KVM guest on Linux gives you a full Windows Server 2022 environment at Linux spot prices.

**Why Windows → WSL2 → Linux (the nesting)?** Many open-source server applications (Frappe, ERPNext, etc.) run on Linux but need to be packaged as Windows installers (.exe) for enterprise users. The stack is:

1. **Linux metal host** — cheap, runs QEMU
2. **Windows VM** — the target platform for building/testing .exe installers
3. **WSL2 inside Windows** — provides the Linux environment (podman, containers) that the installer sets up for end users

This mirrors exactly what an end user's Windows machine looks like, making it the ideal build and test environment.

**Why spot instances?** Metal instances are expensive even on Linux. Spot pricing saves 60-70%. The persistent EBS volume survives spot terminations — your Windows VM, WSL2 setup, and all data persist across spot cycles.

## Architecture

```
┌─────────────────────────────────────────────┐
│  AWS c5.metal spot instance (ap-south-1a)   │
│  Ubuntu 24.04 + QEMU/KVM                    │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │  Windows Server 2022 (QEMU VM)      │    │
│  │  - Activated (ServerStandard)       │    │
│  │  - SSH (port 2222), RDP (3389)      │    │
│  │  - Git, Chocolatey                  │    │
│  │  ┌─────────────────────────────┐    │    │
│  │  │  WSL2 Ubuntu                │    │    │
│  │  │  Kernel 6.6.87             │    │    │
│  │  │  (your dev environment)    │    │    │
│  │  └─────────────────────────────┘    │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  250GB EBS (persistent across spot cycles)  │
│  /var /usr /opt /data                       │
└─────────────────────────────────────────────┘
```

## What you get

- Windows Server 2022 (activated, latest build)
- SSH, RDP access
- Chocolatey, Git
- WSL2 Ubuntu 24.04 with kernel 6.6.87
- Podman + podman-compose for running containerized Linux applications
- Dev tools: gcc, python3, aws-cli, jq, curl

## Prerequisites

1. AWS account with ap-south-1 (Mumbai) access
2. AWS CloudShell (recommended) or any machine with AWS CLI configured
3. Spot vCPU quota of at least 96 for c5.metal ([request increase](https://console.aws.amazon.com/servicequotas))

## Accessing the environment

### SSH into Windows

```bash
bash shazam.sh winssh
# Password: see secrets/admin-password.txt
```

### RDP

Connect your RDP client to `<IP>:3389` (IP shown after `bash shazam.sh`).

### VNC

```bash
ssh -L 5900:localhost:5900 -i ~/.ssh/shazam-* ubuntu@<IP>
# Then connect VNC client to localhost:5900
```

## Cost

| Resource | Cost | When |
|----------|------|------|
| c5.metal spot | ~$1.50/hr | Only while running |
| 250GB EBS | ~$20/month | Always (until `destroy`) |

Run `bash shazam.sh cost` to see current prices.

## Technical details

See [DESIGN.md](DESIGN.md) for:
- Unattended Windows install (autounattend.xml)
- Two-phase setup.ps1 (DISM activation, WSL2, Windows Update)
- QEMU configuration
- Troubleshooting
- Exposing WSL2 services to LAN

## Credits

Co-created with [Kiro](https://kiro.dev) — from spot instance orchestration to QCOW2 snapshot management, every script was pair-programmed in `kiro-cli`.
