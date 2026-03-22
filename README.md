# metal-spot4win

Windows Server 2022 QEMU/KVM dev environment on AWS Linux metal spot instances with WSL2 Ubuntu — for packaging Linux open source software for the Windows ecosystem.

## Why?

- Windows metal instances (e.g., `i3en.metal`) cost ~$5/hr in Mumbai
- Linux metal instances (e.g., `c5.metal`) cost ~$1.5/hr as spot
- This project runs Windows Server 2022 as a QEMU/KVM VM on Linux metal spot instances
- WSL2 inside Windows provides the Linux environment for building/packaging software
- Persistent EBS volume survives spot terminations — no data loss

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

## Prerequisites

1. AWS account with ap-south-1 (Mumbai) access
2. AWS CloudShell or a Linux machine with AWS CLI configured
3. SSH key pair imported to ap-south-1 (this project uses `ett8u-key`)
4. Spot vCPU quota of at least 96 for c5.metal (request increase via Service Quotas)
5. Windows Server 2022 evaluation ISO and VirtIO drivers ISO on the EBS

## One-Time Setup

### 1. Create the persistent EBS volume

```bash
aws ec2 create-volume --region ap-south-1 \
  --availability-zone ap-south-1a \
  --size 250 --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=metal-spot4win}]'
```

Update `VOL_ID` in `launch-metal-spot.sh` with the volume ID.

### 2. Partition and label the EBS (first time only)

Attach the volume to any instance, then:

```bash
sudo parted /dev/nvme1n1 mklabel gpt
sudo parted /dev/nvme1n1 mkpart var ext4 1MiB 24GiB
sudo parted /dev/nvme1n1 mkpart usr ext4 24GiB 72GiB
sudo parted /dev/nvme1n1 mkpart opt ext4 72GiB 192GiB
sudo parted /dev/nvme1n1 mkpart data ext4 192GiB 240GiB

for i in 1 2 3 4; do sudo mkfs.ext4 /dev/nvme1n1p$i; done
sudo e2label /dev/nvme1n1p1 var
sudo e2label /dev/nvme1n1p2 usr
sudo e2label /dev/nvme1n1p3 opt
sudo e2label /dev/nvme1n1p4 data
```

### 3. Download ISOs to /data

```bash
# Mount /data and download
sudo mount LABEL=data /data

# Windows Server 2022 Evaluation ISO (~4.7GB)
# Download from: https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022
# Save as: /data/win2022.iso

# VirtIO drivers ISO (~754MB)
# Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
# Save as: /data/virtio-win.iso
```

### 4. Install QEMU on the EBS /usr

Mount /usr and install QEMU packages — they persist across spot instances:

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf socat dosfstools
```

### 5. Create the floppy image with autounattend.xml and setup.ps1

```bash
dd if=/dev/zero of=/opt/floppy.img bs=1M count=3
mkfs.fat /opt/floppy.img
sudo mount /opt/floppy.img /mnt
sudo cp autounattend.xml /mnt/
sudo cp setup.ps1 /mnt/
sudo umount /mnt
```

### 6. Create hardware ID config

```bash
cat > /opt/hw-id.conf << 'EOF'
QEMU_UUID="062e278c-7902-4e1f-9370-970cae162986"
QEMU_SMBIOS_OPTS="\
  -uuid ${QEMU_UUID} \
  -smbios type=1,manufacturer=QEMU,product=WinDev,version=1.0,serial=WINDEV-001,uuid=${QEMU_UUID} \
  -smbios type=2,manufacturer=QEMU,product=WinDev-Board,serial=BOARD-001 \
  -smbios type=3,manufacturer=QEMU,serial=CHASSIS-001"
EOF
```

## Daily Usage

### Launch a spot instance

```bash
bash launch-metal-spot.sh c5.metal
```

This creates a spot instance, attaches the EBS, and mounts `/var /usr /opt /data` via cloud-init. Instance ID and IP are saved to `.instance-id` and `.instance-ip`.

### Fresh Windows install (from scratch)

```bash
IP=$(cat .instance-ip)
ssh -i ~/.ssh/ett8u-key ubuntu@$IP 'bash /opt/install-windows.sh'
```

Takes ~10 minutes. The install is fully unattended:
1. QEMU boots from Windows ISO with floppy containing `autounattend.xml`
2. VirtIO storage/network drivers loaded during Windows PE
3. Windows installs to VirtIO disk, partitions automatically
4. First login runs `setup.ps1`: SSH, RDP, Chocolatey, Git, WSL features
5. DISM activates Windows (eval → ServerStandard) and reboots
6. `setup-part2.ps1` runs at startup: Windows Update, new WSL 2.6.3, Ubuntu on WSL2

### Run existing Windows VM

```bash
ssh -i ~/.ssh/ett8u-key ubuntu@$IP 'bash /opt/run-windows.sh'
```

### Stop Windows VM

```bash
ssh -i ~/.ssh/ett8u-key ubuntu@$IP 'bash /opt/stop-windows.sh'
```

### SSH into Windows

```bash
ssh -i ~/.ssh/ett8u-key -J ubuntu@$IP -p 2222 Administrator@localhost
# Password: see secrets/admin-password.txt
```

Or from the Linux host:
```bash
sshpass -p "$(cat secrets/admin-password.txt)" ssh -p 2222 Administrator@localhost
```

### VNC access

VNC is on port 5900 of the host. Use SSH tunnel:
```bash
ssh -i ~/.ssh/ett8u-key -L 5900:localhost:5900 ubuntu@$IP
# Then connect VNC client to localhost:5900
```

### RDP access

RDP is forwarded to port 3389 of the host:
```bash
ssh -i ~/.ssh/ett8u-key -L 3389:localhost:3389 ubuntu@$IP
# Then connect RDP client to localhost:3389
# User: Administrator, Password: see secrets/admin-password.txt
```

## File Layout

### On persistent EBS

| Path | Description |
|------|-------------|
| `/opt/install-windows.sh` | Fresh automated Windows install |
| `/opt/run-windows.sh` | Boot existing Windows VM |
| `/opt/stop-windows.sh` | Graceful shutdown with fallback |
| `/opt/hw-id.conf` | Fixed SMBIOS IDs for activation persistence |
| `/opt/floppy.img` | Floppy with autounattend.xml + setup.ps1 |
| `/opt/winserver2022-auto.qcow2` | Current Windows disk image |
| `/data/win2022.iso` | Windows Server 2022 evaluation ISO |
| `/data/virtio-win.iso` | VirtIO drivers ISO |

### In this repo

| File | Description |
|------|-------------|
| `launch-metal-spot.sh` | Launch spot instance + attach EBS |
| `install-windows.sh` | Automated Windows install script |
| `run-windows.sh` | Run existing VM |
| `stop-windows.sh` | Graceful shutdown |
| `hw-id.conf` | Fixed SMBIOS hardware IDs |
| `autounattend.xml` | Windows unattended install answer file |
| `setup.ps1` | Post-install PowerShell (SSH, RDP, Git, activation, WSL2) |

## Key Technical Details

### autounattend.xml

- VirtIO drivers loaded via `Microsoft-Windows-PnpCustomizationsWinPE` component (NOT `Microsoft-Windows-Setup` — this was a critical discovery)
- `DriverPaths` covers both D: and E: for the VirtIO ISO (drive letter varies)
- Image selection: `INDEX=2` = Windows Server 2022 Standard (Desktop Experience)
- No `ProductKey` in XML (evaluation ISO rejects KMS/retail keys during install)
- `FirstLogonCommands` calls `A:\setup.ps1` (floppy drive)

### setup.ps1 (two-phase)

Phase 1 (FirstLogonCommands):
- DNS, SSH server, RDP, Chocolatey, Git
- WSL features enabled (Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform)
- WSL2 kernel MSI installed
- Part2 scheduled as SYSTEM AtStartup task
- DISM activation last (forces reboot)

Phase 2 (after reboot, as SYSTEM):
- Windows Update to latest build (needed for new WSL)
- WSL 2.6.3 MSI from GitHub (inbox wsl.exe is broken on Server 2022)
- `wsl --set-default-version 2` + `wsl --install Ubuntu`

### Why two phases?

1. DISM `/set-edition` forces an immediate reboot — anything after it won't run
2. WSL2 features need a reboot to take effect
3. The new WSL MSI from GitHub requires a newer Windows build (20348.2700+)
4. Windows Update must run as SYSTEM (fails over SSH as regular user)

### QEMU command line

```bash
qemu-system-x86_64 -enable-kvm -m 16G -smp 8 -cpu host \
  -machine q35 -bios /usr/share/ovmf/OVMF.fd \
  -uuid 062e278c-7902-4e1f-9370-970cae162986 \
  -smbios type=1,manufacturer=QEMU,product=WinDev,... \
  -drive file=/opt/winserver2022-auto.qcow2,format=qcow2,if=virtio \
  -drive file=/data/win2022.iso,media=cdrom,index=0 \
  -drive file=/data/virtio-win.iso,media=cdrom,index=1 \
  -fda /opt/floppy.img \
  -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -vga qxl -display none -vnc :0 \
  -device usb-ehci -device usb-tablet \
  -monitor unix:/tmp/qemu-mon.sock,server,nowait
```

Key points:
- `-machine q35` required for UEFI SATA CD-ROM boot
- `-bios /usr/share/ovmf/OVMF.fd` (not pflash — pflash drops to EFI shell)
- `-if=virtio` for disk (requires viostor driver in autounattend)
- `-device virtio-net-pci` for network (requires NetKVM driver)
- `-fda` for floppy with autounattend.xml
- `-device usb-ehci -device usb-tablet` for VNC mouse (not `-usbdevice tablet`)
- "Press any key to boot from CD" handled by key spam loop

## Troubleshooting

### "Component or setting does not exist" in autounattend
- `DriverPaths` is in the wrong component. Must be `Microsoft-Windows-PnpCustomizationsWinPE`, not `Microsoft-Windows-Setup`.

### "Internal error loading answer file"
- Special characters in `FirstLogonCommands` XML. Move complex logic to a .ps1 file on the floppy and call it with `powershell.exe -File A:\setup.ps1`.

### Windows can't see the disk during install
- VirtIO storage driver not loaded. Ensure `DriverPaths` includes paths to `viostor\2k22\amd64` on the VirtIO ISO.

### WSL shows version 1 / wsl.exe prints help for all commands
- Inbox `wsl.exe` on Server 2022 build 20348.587 is broken. Install WSL 2.6.3 MSI from GitHub and use `"C:\Program Files\WSL\wsl.exe"` directly. Requires Windows Update to build 20348.2700+.

### QEMU monitor sendkey doesn't work for complex commands
- Use `vncdotool` for VNC interaction: `pip3 install vncdotool && vncdo -s localhost::5900 move X Y click 1`

### Spot instance terminated, data lost?
- All important data is on the persistent EBS volume. Just launch a new instance with `launch-metal-spot.sh`.
