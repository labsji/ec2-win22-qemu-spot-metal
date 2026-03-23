# Design & Technical Details

## Unattended Windows Install

### autounattend.xml

- VirtIO drivers loaded via `Microsoft-Windows-PnpCustomizationsWinPE` component (NOT `Microsoft-Windows-Setup` — this was a critical discovery)
- `DriverPaths` covers both D: and E: for the VirtIO ISO (drive letter varies)
- Image selection: `INDEX=2` = Windows Server 2022 Standard (Desktop Experience)
- No `ProductKey` in XML (evaluation ISO rejects KMS/retail keys during install)
- `FirstLogonCommands` calls `A:\setup.ps1` (floppy drive)
- Password placeholder `@@ADMIN_PASSWORD@@` injected by `build-floppy.sh`

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
- Dev tools: gcc, python3, aws-cli, jq, podman, podman-compose

### Why two phases?

1. DISM `/set-edition` forces an immediate reboot — anything after it won't run
2. WSL2 features need a reboot to take effect
3. The new WSL MSI from GitHub requires a newer Windows build (20348.2700+)
4. Windows Update must run as SYSTEM (fails over SSH as regular user)

## QEMU Configuration

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

### In the repo

| File | Description |
|------|-------------|
| `shazam.sh` | Single entry point — up/down/destroy/ssh/status/cost |
| `launch-metal-spot.sh` | Launch spot instance + attach EBS |
| `install-windows.sh` | Automated Windows install script |
| `run-windows.sh` | Run existing VM |
| `stop-windows.sh` | Graceful shutdown |
| `build-floppy.sh` | Build floppy image with secrets injection |
| `hw-id.conf` | Fixed SMBIOS hardware IDs |
| `autounattend.xml` | Windows unattended install answer file |
| `setup.ps1` | Post-install PowerShell (SSH, RDP, Git, activation, WSL2) |
| `activation-key.txt` | Template placeholder for public repo |
| `admin-password.txt` | Template placeholder for public repo |
| `secrets/` | Git submodule → private CodeCommit repo with real keys |

## First-Time EBS Setup

On the very first run, the EBS volume needs partitioning and ISOs:

### Partition and label

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

### Download ISOs

```bash
# Windows Server 2022 Evaluation (~4.7GB)
# https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022
# Save as: /data/win2022.iso

# VirtIO drivers (~754MB)
# https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
# Save as: /data/virtio-win.iso
```

### Install QEMU

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf socat dosfstools
```

## Troubleshooting

### "Component or setting does not exist" in autounattend
`DriverPaths` is in the wrong component. Must be `Microsoft-Windows-PnpCustomizationsWinPE`, not `Microsoft-Windows-Setup`.

### "Internal error loading answer file"
Special characters in `FirstLogonCommands` XML. Move complex logic to a .ps1 file on the floppy and call it with `powershell.exe -File A:\setup.ps1`.

### Windows can't see the disk during install
VirtIO storage driver not loaded. Ensure `DriverPaths` includes paths to `viostor\2k22\amd64` on the VirtIO ISO.

### WSL shows version 1 / wsl.exe prints help for all commands
Inbox `wsl.exe` on Server 2022 build 20348.587 is broken. Install WSL 2.6.3 MSI from GitHub and use `"C:\Program Files\WSL\wsl.exe"` directly. Requires Windows Update to build 20348.2700+.

### QEMU monitor sendkey doesn't work for complex commands
Use `vncdotool` for VNC interaction: `pip3 install vncdotool && vncdo -s localhost::5900 move X Y click 1`

### Spot instance terminated, data lost?
All important data is on the persistent EBS volume. Just run `bash shazam.sh` again.

## Exposing WSL2 services to LAN

WSL2 runs in a virtual network. To expose a service (e.g., a web app on port 8080) to other machines:

```powershell
$wslIp = (& "C:\Program Files\WSL\wsl.exe" -u root -- hostname -I).Trim()
netsh interface portproxy add v4tov4 listenport=9080 listenaddress=0.0.0.0 connectport=8080 connectaddress=$wslIp
netsh advfirewall firewall add rule name="WSL-9080" dir=in action=allow protocol=TCP localport=9080
```

Note: WSL IP changes on reboot. The port proxy must be updated after each restart.
