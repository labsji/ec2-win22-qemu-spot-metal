# DESIGN.md — metal-spot4win v2

## Architecture: Snapshot-as-Persistence, Multi-VM

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS metal spot instance (m5d.metal, ap-south-1a)               │
│  Ubuntu 24.04 + QEMU/KVM                                       │
│                                                                 │
│  /data (EBS vol, LABEL=data)        ← ISOs, shared tools       │
│  /vm/ikuku (EBS vol, LABEL=win-ikuku)    ← QCOW2 + state       │
│  /vm/prospect (EBS vol, LABEL=win-prospect) ← QCOW2 + state    │
│                                                                 │
│  ┌────────────────────┐  ┌────────────────────┐                 │
│  │ VM: ikuku          │  │ VM: prospect       │                 │
│  │ SSH:2222 RDP:3389  │  │ SSH:2223 RDP:3390  │                 │
│  │ VNC:5900           │  │ VNC:5901           │                 │
│  │ Windows Server 2022│  │ Windows Server 2022│                 │
│  │ + WSL2 + podman    │  │ (clean prospect)   │                 │
│  └────────────────────┘  └────────────────────┘                 │
└─────────────────────────────────────────────────────────────────┘
```

## Key Principles

### 1. Volumes are ephemeral, snapshots are truth

- On `shazam up`: create fresh volumes from latest snapshots
- On `shazam down`: snapshot all volumes, then delete them
- Spot reclaim? No problem — snapshot already exists, create new volume from it
- No force-detach needed. No data loss risk.

### 2. One filesystem per volume

- No partitions. Each volume = one ext4 filesystem with a LABEL.
- Cloud-init mounts by LABEL (order-independent, self-describing).
- Volume corruption affects only that one VM, not the whole system.

### 3. Multi-VM via separate volumes

- Each Windows VM gets its own EBS volume (100GB gp3, ~$8/mo as snapshot)
- Port mapping: slot-based (VM index determines SSH/RDP/VNC ports)
- Clone: snapshot one VM, create another from it (30 seconds)

## Volume Layout

| LABEL | Mount | Size | Type | Content |
|-------|-------|------|------|---------|
| `data` | /data | 20GB | gp3 | win2022.iso, virtio-win.iso |
| `win-ikuku` | /vm/ikuku | 100GB | gp3 | disk.qcow2 (Windows + WSL2 + ikuku tests) |
| `win-prospect` | /vm/prospect | 100GB | gp3 | disk.qcow2 (clean Windows for prospect sim) |

## Port Mapping

| VM (slot) | Linux SSH | Win SSH | Win RDP | VNC |
|-----------|-----------|---------|---------|-----|
| (host) | 22 | - | - | - |
| ikuku (0) | - | 2222 | 3389 | 5900 |
| prospect (1) | - | 2223 | 3390 | 5901 |
| erpgulf (2) | - | 2224 | 3391 | 5902 |

## Lifecycle

```
First time:
  shazam up ikuku        → creates fresh volumes, installs QEMU
  shazam install ikuku   → installs Windows (30 min)
  shazam snapshot ikuku  → saves the golden image
  shazam clone ikuku prospect  → creates prospect from golden image

Normal use:
  shazam up              → creates volumes from snapshots, boots all VMs
  (work, test, develop)
  shazam down            → snapshots everything, terminates, deletes volumes

Spot reclaim recovery:
  (instance dies)
  shazam up              → new instance, new volumes from existing snapshots
  (continues from last snapshot — at most minutes of work lost)
```

## Cost

| Resource | Cost | When |
|----------|------|------|
| m5d.metal spot | ~$0.78/hr | Only while running |
| Snapshots | ~$0.05/GB/mo | Always (actual data, not provisioned size) |
| Typical: 1 VM (50GB actual data) | ~$2.50/mo | Snapshot storage |
| During run: volumes exist | ~$0.08/GB/mo pro-rated | Only during session |

**Monthly cost when not running:** ~$5 for 2 VM snapshots + data snapshot.
**Hourly cost when running:** ~$0.80 (spot) + negligible volume cost.

## Commands Reference

| Command | Action |
|---------|--------|
| `shazam up [vm1,vm2]` | Launch instance, create volumes from snapshots, boot VMs |
| `shazam down` | Snapshot + terminate + delete volumes |
| `shazam ssh` | SSH to Linux host |
| `shazam winssh <vm>` | SSH to Windows VM |
| `shazam status` | Show instance + snapshot state |
| `shazam snapshot <vm>` | Manual snapshot of running VM |
| `shazam clone <src> <dst>` | Clone a VM (snapshot → new VM name) |
| `shazam install <vm>` | Fresh Windows install on empty VM volume |
| `shazam list` | List all VM snapshots |
| `shazam cost` | Show current costs |
| `shazam destroy` | Delete EVERYTHING (snapshots, SG, key) |

## Recovery from Previous Design

The old design used a single 250GB volume with multiple partitions. That volume
and its snapshot have been deleted. Starting fresh with the multi-volume design.

First session will:
1. `shazam up ikuku` → fresh volumes, downloads ISOs
2. `shazam install ikuku` → Windows install (~30 min)
3. `shazam snapshot ikuku` → golden image saved
4. Future sessions boot in ~3 min from snapshot
