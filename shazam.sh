#!/bin/bash
set -euo pipefail
# shazam.sh - Multi-VM Windows dev environment on AWS metal spot
# Snapshot-as-persistence: volumes are ephemeral, snapshots are truth.
#
# Usage:
#   bash shazam.sh up [vm1,vm2]     # launch with specific VMs (default: all)
#   bash shazam.sh down             # snapshot + terminate (zero ongoing cost except snapshots)
#   bash shazam.sh destroy          # delete ALL (snapshots, SG, key)
#   bash shazam.sh ssh              # SSH into Linux host
#   bash shazam.sh winssh <vm>      # SSH into Windows VM
#   bash shazam.sh status           # show current state
#   bash shazam.sh cost             # show estimated running cost
#   bash shazam.sh snapshot <vm>    # manual snapshot of a VM volume
#   bash shazam.sh clone <src> <dst># clone a VM (snapshot src, create dst from it)
#   bash shazam.sh install <vm>     # fresh Windows install on a new VM
#   bash shazam.sh list             # list available VM snapshots

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export AWS_PAGER=""
STATE="$SCRIPT_DIR/.shazam-state"
INSTANCE_TYPE="${SHAZAM_INSTANCE_TYPE:-m5d.metal}"
TAG_PREFIX="shazam"

# Port mapping: each VM gets a slot (0-based index)
# Slot 0: SSH=2222, RDP=3389, VNC=5900
# Slot 1: SSH=2223, RDP=3390, VNC=5901
# Slot N: SSH=2222+N, RDP=3389+N, VNC=5900+N

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "➡️  $1"; }
warn() { echo "⚠️  $1"; }

# --- Preflight ---
preflight() {
    command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Are you in AWS CloudShell?"
    aws sts get-caller-identity > /dev/null 2>&1 || die "AWS credentials not configured."
    REGION=$(aws configure get region 2>/dev/null || echo "")
    [ -z "$REGION" ] && REGION=$AWS_DEFAULT_REGION
    [ -z "$REGION" ] && die "No region set. Run: aws configure set region ap-south-1"
    export AWS_DEFAULT_REGION="$REGION"
}

load() { [ -f "$STATE" ] && source "$STATE" || true; }

save() {
    cat > "$STATE" << EOF
REGION="$REGION"
SG_ID="${SG_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
KEY_NAME="${KEY_NAME:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
ACTIVE_VMS="${ACTIVE_VMS:-}"
EOF
}

# --- Snapshot helpers ---
# Find latest snapshot for a given VM name
find_snapshot() {
    local vm="$1"
    aws ec2 describe-snapshots --owner-ids self \
        --filters "Name=tag:$TAG_PREFIX-vm,Values=$vm" \
        --query 'Snapshots | sort_by(@, &StartTime) | [-1].SnapshotId' \
        --output text 2>/dev/null | grep -v None || echo ""
}

# Find the data volume snapshot
find_data_snapshot() {
    aws ec2 describe-snapshots --owner-ids self \
        --filters "Name=tag:$TAG_PREFIX-role,Values=data" \
        --query 'Snapshots | sort_by(@, &StartTime) | [-1].SnapshotId' \
        --output text 2>/dev/null | grep -v None || echo ""
}

# Create a volume from snapshot or fresh
create_volume() {
    local label="$1" size="$2" snap="${3:-}" type="${4:-gp3}"
    local args="--availability-zone $AZ --size $size --volume-type $type"
    args="$args --tag-specifications ResourceType=volume,Tags=[{Key=Name,Value=$TAG_PREFIX-$label},{Key=$TAG_PREFIX-label,Value=$label}]"
    [ -n "$snap" ] && args="$args --snapshot-id $snap"
    aws ec2 create-volume $args --query 'VolumeId' --output text
}

# Snapshot a volume with tags
snapshot_volume() {
    local vol_id="$1" vm_name="$2" role="${3:-vm}"
    local desc="$TAG_PREFIX: $vm_name ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
    local snap_id=$(aws ec2 create-snapshot --volume-id "$vol_id" --description "$desc" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$TAG_PREFIX-$vm_name},{Key=$TAG_PREFIX-vm,Value=$vm_name},{Key=$TAG_PREFIX-role,Values=$role}]" \
        --query 'SnapshotId' --output text)
    echo "$snap_id"
}

# Wait for volume to be available
wait_volume() {
    aws ec2 wait volume-available --volume-ids "$1"
}

# Attach volume to instance
attach_volume() {
    local vol_id="$1" device="$2"
    aws ec2 attach-volume --volume-id "$vol_id" --instance-id "$INSTANCE_ID" --device "$device" > /dev/null
    aws ec2 wait volume-in-use --volume-ids "$vol_id"
}

# --- Up ---
cmd_up() {
    local vms="${1:-}"
    preflight; load

    # SSH key
    KEY_NAME="${KEY_NAME:-shazam-$(whoami)}"
    KEY_FILE="$HOME/.ssh/$KEY_NAME"
    if [ ! -f "$KEY_FILE" ]; then
        info "Creating SSH key..."
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -q
    fi
    aws ec2 describe-key-pairs --key-names "$KEY_NAME" > /dev/null 2>&1 || \
        aws ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material fileb://"$KEY_FILE.pub" > /dev/null

    # Security group
    if [ -z "${SG_ID:-}" ]; then
        info "Creating security group..."
        VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
        SG_ID=$(aws ec2 create-security-group --group-name "$TAG_PREFIX-$REGION" --description "metal-spot4win" --vpc-id "$VPC_ID" --query 'GroupId' --output text 2>/dev/null || \
            aws ec2 describe-security-groups --group-names "$TAG_PREFIX-$REGION" --query 'SecurityGroups[0].GroupId' --output text)
        # Ports: SSH(22), VMs(2222-2230, 3389-3395, 5900-5905), ERPNext(8000-8005)
        for port in 22 2222-2230 3389-3395 5900-5905 8000-8005; do
            aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port $port --cidr 0.0.0.0/0 2>/dev/null || true
        done
    fi

    # Subnet + AZ
    if [ -z "${SUBNET_ID:-}" ]; then
        SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" --query 'Subnets[0].SubnetId' --output text)
    fi
    AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)

    # Determine which VMs to launch
    if [ -z "$vms" ]; then
        # Auto-discover from existing snapshots
        vms=$(aws ec2 describe-snapshots --owner-ids self \
            --filters "Name=tag-key,Values=$TAG_PREFIX-vm" \
            --query 'Snapshots[*].Tags[?Key==`'$TAG_PREFIX'-vm`].Value | []' \
            --output text 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    [ -z "$vms" ] && vms="ikuku"  # default first VM
    ACTIVE_VMS="$vms"

    # Create volumes from snapshots
    info "Preparing volumes for VMs: $vms"
    local vol_ids="" device_idx=1
    local devices=(/dev/xvdf /dev/xvdg /dev/xvdh /dev/xvdi /dev/xvdj /dev/xvdk)

    # Data volume
    local data_snap=$(find_data_snapshot)
    local data_vol=""
    if [ -n "$data_snap" ]; then
        info "  data: from snapshot $data_snap"
        data_vol=$(create_volume "data" 20 "$data_snap" "gp3")
    else
        info "  data: fresh 20GB (will download ISOs)"
        data_vol=$(create_volume "data" 20 "" "gp3")
    fi
    wait_volume "$data_vol"

    # VM volumes
    local vm_vols=""
    IFS=',' read -ra VM_LIST <<< "$vms"
    for vm in "${VM_LIST[@]}"; do
        vm=$(echo "$vm" | xargs)
        local snap=$(find_snapshot "$vm")
        if [ -n "$snap" ]; then
            info "  $vm: from snapshot $snap"
            local vol=$(create_volume "win-$vm" 100 "$snap")
        else
            info "  $vm: fresh 100GB (needs Windows install)"
            local vol=$(create_volume "win-$vm" 100)
        fi
        wait_volume "$vol"
        vm_vols="$vm_vols $vm:$vol"
    done

    # Launch instance
    AMI=$(aws ec2 describe-images --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

    # Build userdata
    local userdata=$(generate_userdata "$vms")

    info "Launching $INSTANCE_TYPE spot instance..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
        --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}' \
        --associate-public-ip-address \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_PREFIX-$REGION}]" \
        --user-data "$userdata" \
        --query 'Instances[0].InstanceId' --output text 2>/dev/null) || true
    [ -z "${INSTANCE_ID:-}" ] && die "Launch failed. $INSTANCE_TYPE spot unavailable. Check spot vCPU quota."

    info "Waiting for instance..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    # Attach volumes
    info "Attaching data volume..."
    attach_volume "$data_vol" "${devices[0]}"

    local idx=1
    for entry in $vm_vols; do
        local vm="${entry%%:*}" vol="${entry##*:}"
        info "Attaching $vm volume..."
        attach_volume "$vol" "${devices[$idx]}"
        idx=$((idx + 1))
    done

    save

    # Wait for cloud-init
    info "Waiting for cloud-init + QEMU..."
    for i in $(seq 1 60); do
        STATUS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_FILE" "ubuntu@$PUBLIC_IP" "cloud-init status 2>/dev/null || echo running" 2>/dev/null)
        case "$STATUS" in *done*|*error*) break ;; esac
        sleep 10
    done

    # Copy scripts if needed
    copy_scripts

    show_info
}

# --- Generate cloud-init userdata ---
generate_userdata() {
    local vms="$1"
    cat << 'USERDATA'
#!/bin/bash
set -e
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 qemu-utils ovmf sshpass socat genisoimage > /dev/null 2>&1

# Mount volumes by label (self-describing, order-independent)
mkdir -p /data /vm
for dev in /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1 /dev/nvme5n1; do
    [ -b "$dev" ] || continue
    LABEL=$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)
    [ -z "$LABEL" ] && continue
    case "$LABEL" in
        data)    mount "$dev" /data ;;
        win-*)   VM_NAME="${LABEL#win-}"; mkdir -p "/vm/$VM_NAME"; mount "$dev" "/vm/$VM_NAME" ;;
    esac
done

# Also check partition devices (nvmeXn1p1 etc) for unpartitioned volumes
for dev in /dev/nvme{1..5}n1; do
    [ -b "$dev" ] || continue
    # Skip if already mounted
    mountpoint -q "$dev" 2>/dev/null && continue
    grep -q "$dev " /proc/mounts && continue
    LABEL=$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)
    [ -z "$LABEL" ] && continue
    case "$LABEL" in
        data)    mountpoint -q /data || mount "$dev" /data ;;
        win-*)   VM_NAME="${LABEL#win-}"; mkdir -p "/vm/$VM_NAME"; mountpoint -q "/vm/$VM_NAME" || mount "$dev" "/vm/$VM_NAME" ;;
    esac
done

# Format any unformatted volumes (new/fresh)
# Use size to determine role: <=30GB = data, >30GB = win-vm
VM_SLOT=0
for dev in /dev/nvme{1..8}n1; do
    [ -b "$dev" ] || continue
    LABEL=$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)
    [ -n "$LABEL" ] && continue
    # Skip the root disk and instance store (>200GB)
    SIZE_GB=$(lsblk -bno SIZE "$dev" 2>/dev/null | awk '{printf "%d", $1/1073741824}')
    [ "$SIZE_GB" -gt 200 ] && continue
    [ "$SIZE_GB" -eq 0 ] && continue
    if [ "$SIZE_GB" -le 30 ]; then
        mkfs.ext4 -q -L data "$dev"
        mount "$dev" /data
        echo "Formatted $dev as data (${SIZE_GB}GB)"
    else
        VM_NAME="vm${VM_SLOT}"
        mkfs.ext4 -q -L "win-${VM_NAME}" "$dev"
        mkdir -p "/vm/${VM_NAME}"
        mount "$dev" "/vm/${VM_NAME}"
        echo "Formatted $dev as win-${VM_NAME} (${SIZE_GB}GB)"
        VM_SLOT=$((VM_SLOT+1))
    fi
done

# Download ISOs if data volume is empty
if mountpoint -q /data && [ ! -f /data/win2022.iso ]; then
    echo "Downloading Windows Server 2022 eval ISO..."
    curl -fsSL -o /data/win2022.iso "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US" || true
    curl -fsSL -o /data/virtio-win.iso "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" || true
fi

# Start QEMU for each VM that has a disk.qcow2
SLOT=0
for vmdir in /vm/*/; do
    [ -d "$vmdir" ] || continue
    VM_NAME=$(basename "$vmdir")
    QCOW="$vmdir/disk.qcow2"
    [ -f "$QCOW" ] || { SLOT=$((SLOT+1)); continue; }

    SSH_PORT=$((2222 + SLOT))
    RDP_PORT=$((3389 + SLOT))
    VNC_DISPLAY=$SLOT

    echo "Starting VM: $VM_NAME (SSH:$SSH_PORT RDP:$RDP_PORT VNC:$VNC_DISPLAY)"
    nohup qemu-system-x86_64 -enable-kvm -m 16G -smp 8 -cpu host \
        -machine q35 -bios /usr/share/ovmf/OVMF.fd \
        -drive file="$QCOW",format=qcow2,if=virtio \
        -drive file=/data/virtio-win.iso,media=cdrom,index=1 \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${RDP_PORT}-:3389 \
        -device virtio-net-pci,netdev=net0 \
        -vga qxl -display none -vnc :${VNC_DISPLAY} \
        -device usb-ehci -device usb-tablet \
        -monitor unix:/tmp/qemu-mon-${VM_NAME}.sock,server,nowait \
        > /tmp/qemu-${VM_NAME}.log 2>&1 &

    SLOT=$((SLOT+1))
done
USERDATA
}

# --- Copy helper scripts to host ---
copy_scripts() {
    local key="$HOME/.ssh/$KEY_NAME"
    scp -o StrictHostKeyChecking=no -i "$key" \
        "$SCRIPT_DIR/install-windows.sh" "$SCRIPT_DIR/run-windows.sh" \
        "$SCRIPT_DIR/stop-windows.sh" "$SCRIPT_DIR/hw-id.conf" \
        "ubuntu@$PUBLIC_IP:/tmp/" 2>/dev/null || true
    ssh -o StrictHostKeyChecking=no -i "$key" "ubuntu@$PUBLIC_IP" \
        "sudo mkdir -p /opt/shazam && sudo cp /tmp/install-windows.sh /tmp/run-windows.sh /tmp/stop-windows.sh /tmp/hw-id.conf /opt/shazam/ && sudo chmod +x /opt/shazam/*.sh" 2>/dev/null || true
}

# --- Show info ---
show_info() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  🪟 Windows Dev Environment Ready            ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "  Instance:  $INSTANCE_ID ($INSTANCE_TYPE)"
    echo "  IP:        $PUBLIC_IP"
    echo "  Region:    $REGION"
    echo ""
    IFS=',' read -ra VM_LIST <<< "$ACTIVE_VMS"
    local slot=0
    for vm in "${VM_LIST[@]}"; do
        vm=$(echo "$vm" | xargs)
        echo "  VM [$vm]: SSH :$((2222+slot)) | RDP :$((3389+slot)) | VNC :$((5900+slot))"
        slot=$((slot+1))
    done
    echo ""
    echo "  Linux SSH: bash shazam.sh ssh"
    echo "  Win SSH:   bash shazam.sh winssh <vm-name>"
    echo ""
    echo "  💰 Cost:   ~\$0.80/hr (m5d.metal spot)"
    echo "  ⏹  Stop:   bash shazam.sh down"
    echo "╚══════════════════════════════════════════════╝"
}

# --- Down (snapshot + terminate + delete volumes) ---
cmd_down() {
    preflight; load
    [ -z "${INSTANCE_ID:-}" ] && die "No instance running."

    local key="$HOME/.ssh/$KEY_NAME"

    # Graceful QEMU shutdown
    info "Shutting down VMs gracefully..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$key" "ubuntu@$PUBLIC_IP" \
        "for sock in /tmp/qemu-mon-*.sock; do echo 'system_powerdown' | sudo socat - UNIX-CONNECT:\$sock 2>/dev/null; done" 2>/dev/null || true
    sleep 10

    # Snapshot all attached volumes (except root)
    info "Snapshotting volumes..."
    local vols=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
        --query 'Volumes[?Attachments[0].Device!=`/dev/sda1`].[VolumeId,Tags[?starts_with(Key,`'$TAG_PREFIX'`)]]' \
        --output json 2>/dev/null)

    # Get volume IDs attached to this instance (non-root)
    local vol_ids=$(aws ec2 describe-volumes \
        --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
        --query 'Volumes[?Attachments[0].Device!=`/dev/sda1`].VolumeId' --output text)

    for vol_id in $vol_ids; do
        local label=$(aws ec2 describe-volumes --volume-ids "$vol_id" \
            --query 'Volumes[0].Tags[?Key==`'$TAG_PREFIX'-label`].Value | [0]' --output text 2>/dev/null)
        [ "$label" = "None" ] && label="unknown"
        local role="vm"
        [[ "$label" == "data" ]] && role="data"
        local vm_name="${label#win-}"
        [[ "$label" == "data" ]] && vm_name="data"
        info "  Snapshotting $label → $vol_id"
        snapshot_volume "$vol_id" "$vm_name" "$role"
    done

    # Terminate instance
    info "Terminating instance..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null

    # Wait and delete volumes (snapshots are the source of truth now)
    info "Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || sleep 30

    for vol_id in $vol_ids; do
        aws ec2 delete-volume --volume-id "$vol_id" 2>/dev/null && info "  Deleted volume $vol_id" || warn "  Could not delete $vol_id (will retry)"
    done

    INSTANCE_ID=""; PUBLIC_IP=""; ACTIVE_VMS=""
    save
    info "Done. Snapshots preserved. Zero ongoing compute cost."
}

# --- Snapshot a specific VM ---
cmd_snapshot() {
    local vm="${1:-}" label="${2:-}"
    [ -z "$vm" ] && die "Usage: bash shazam.sh snapshot <vm-name> [label]"
    preflight; load
    [ -z "${INSTANCE_ID:-}" ] && die "No instance running."

    # Find the volume for this VM
    local vol_id=$(aws ec2 describe-volumes \
        --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" "Name=tag:$TAG_PREFIX-label,Values=win-$vm" \
        --query 'Volumes[0].VolumeId' --output text)
    [ "$vol_id" = "None" ] && die "No volume found for VM '$vm'"

    local date_tag=$(date -u +%Y%m%d-%H%M)
    local snap_name="$TAG_PREFIX-$vm-$date_tag${label:+-$label}"
    local desc="$snap_name"

    info "Snapshotting $vm ($vol_id) → $snap_name"
    local snap_id=$(aws ec2 create-snapshot --volume-id "$vol_id" --description "$desc" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$snap_name},{Key=$TAG_PREFIX-vm,Value=$vm},{Key=$TAG_PREFIX-role,Value=vm}]" \
        --query 'SnapshotId' --output text)
    info "Created: $snap_id ($snap_name)"
}

# --- Clone a VM ---
cmd_clone() {
    local src="${1:-}" dst="${2:-}"
    [ -z "$src" ] || [ -z "$dst" ] && die "Usage: bash shazam.sh clone <source-vm> <dest-vm>"
    preflight; load

    # Find source snapshot (or create one if instance running)
    local snap=""
    if [ -n "${INSTANCE_ID:-}" ]; then
        local vol_id=$(aws ec2 describe-volumes \
            --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" "Name=tag:$TAG_PREFIX-label,Values=win-$src" \
            --query 'Volumes[0].VolumeId' --output text 2>/dev/null)
        if [ "$vol_id" != "None" ] && [ -n "$vol_id" ]; then
            info "Snapshotting $src for clone..."
            snap=$(snapshot_volume "$vol_id" "$src" "vm")
            info "Waiting for snapshot..."
            aws ec2 wait snapshot-completed --snapshot-ids "$snap"
        fi
    fi

    # Fall back to existing snapshot
    [ -z "$snap" ] && snap=$(find_snapshot "$src")
    [ -z "$snap" ] && die "No snapshot found for '$src'. Run the VM first, then snapshot it."

    # Re-tag snapshot copy as the destination VM
    info "Cloning $src → $dst (from $snap)"
    aws ec2 create-tags --resources "$snap" --tags "Key=$TAG_PREFIX-vm,Value=$dst" 2>/dev/null || true

    # Actually we want a NEW snapshot tagged for dst, not re-tag src
    # Copy the snapshot with new tags
    local dst_snap=$(aws ec2 copy-snapshot --source-snapshot-id "$snap" --source-region "$REGION" \
        --description "$TAG_PREFIX: $dst cloned from $src" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$TAG_PREFIX-$dst},{Key=$TAG_PREFIX-vm,Value=$dst},{Key=$TAG_PREFIX-role,Values=vm}]" \
        --query 'SnapshotId' --output text)
    info "Clone snapshot: $dst_snap (copying in background)"
    info "Next 'shazam up $dst' will use this snapshot."
}

# --- Install Windows on a new VM ---
cmd_install() {
    local vm="${1:-}"
    [ -z "$vm" ] && die "Usage: bash shazam.sh install <vm-name>"
    preflight; load
    [ -z "${INSTANCE_ID:-}" ] && die "No instance running. Run: bash shazam.sh up $vm"

    local key="$HOME/.ssh/$KEY_NAME"

    # Check if VM volume is mounted and has no disk yet
    info "Installing Windows on VM: $vm"
    info "This takes ~30 minutes. Monitor: bash shazam.sh ssh, then tail -f /tmp/win-install-$vm.log"

    # Build floppy image for unattended install
    [ -f "$SCRIPT_DIR/floppy.img" ] || bash "$SCRIPT_DIR/build-floppy.sh"
    scp -o StrictHostKeyChecking=no -i "$key" "$SCRIPT_DIR/floppy.img" "ubuntu@$PUBLIC_IP:/tmp/"

    ssh -o StrictHostKeyChecking=no -i "$key" "ubuntu@$PUBLIC_IP" "sudo bash /opt/shazam/install-windows.sh $vm" &
    info "Install started in background."
}

# --- List available VM snapshots ---
cmd_list() {
    preflight
    info "Available VM snapshots:"
    aws ec2 describe-snapshots --owner-ids self \
        --filters "Name=tag-key,Values=$TAG_PREFIX-vm" \
        --query 'Snapshots[*].[Tags[?Key==`'$TAG_PREFIX'-vm`].Value | [0], StartTime, VolumeSize, SnapshotId]' \
        --output table
}

# --- SSH commands ---
cmd_ssh() {
    load
    [ -z "${PUBLIC_IP:-}" ] && die "No instance running."
    ssh -o StrictHostKeyChecking=no -i "$HOME/.ssh/$KEY_NAME" "ubuntu@$PUBLIC_IP"
}

cmd_winssh() {
    local vm="${1:-}"
    load
    [ -z "${PUBLIC_IP:-}" ] && die "No instance running."

    # Find the port for this VM
    local slot=0
    IFS=',' read -ra VM_LIST <<< "$ACTIVE_VMS"
    for v in "${VM_LIST[@]}"; do
        v=$(echo "$v" | xargs)
        [ "$v" = "$vm" ] && break
        slot=$((slot+1))
    done
    local port=$((2222 + slot))
    ssh -o StrictHostKeyChecking=no -p "$port" "Administrator@$PUBLIC_IP"
}

# --- Status ---
cmd_status() {
    preflight; load
    if [ -z "${INSTANCE_ID:-}" ]; then
        echo "No instance running."
    else
        local istate=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
        echo "Instance:  $INSTANCE_ID ($istate)"
        echo "Type:      $INSTANCE_TYPE"
        echo "IP:        ${PUBLIC_IP:-none}"
        echo "VMs:       ${ACTIVE_VMS:-none}"
        echo "Region:    $REGION"
    fi
    echo ""
    echo "Snapshots:"
    aws ec2 describe-snapshots --owner-ids self \
        --filters "Name=tag-key,Values=$TAG_PREFIX-vm" \
        --query 'Snapshots[*].[Tags[?Key==`'$TAG_PREFIX'-vm`].Value | [0], StartTime, State]' \
        --output table 2>/dev/null || echo "  (none)"
}

# --- Cost ---
cmd_cost() {
    preflight; load
    if [ -n "${INSTANCE_ID:-}" ]; then
        local price=$(aws ec2 describe-spot-price-history --instance-types "$INSTANCE_TYPE" \
            --product-descriptions "Linux/UNIX" --max-items 1 \
            --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null || echo "unknown")
        echo "Spot price: \$$price/hr ($INSTANCE_TYPE in $REGION)"
    else
        echo "No instance running."
    fi
    # Count snapshots
    local snap_count=$(aws ec2 describe-snapshots --owner-ids self \
        --filters "Name=tag-key,Values=$TAG_PREFIX-vm" \
        --query 'length(Snapshots)' --output text 2>/dev/null || echo 0)
    local snap_size=$(aws ec2 describe-snapshots --owner-ids self \
        --filters "Name=tag-key,Values=$TAG_PREFIX-vm" \
        --query 'sum(Snapshots[].VolumeSize)' --output text 2>/dev/null || echo 0)
    echo "Snapshots: $snap_count (max ${snap_size}GB → ~\$$(echo "$snap_size * 0.05" | bc 2>/dev/null || echo '?')/mo)"
    echo ""
    echo "Ongoing costs (when stopped): snapshot storage only (~\$0.05/GB/mo)"
    warn "Remember to run 'bash shazam.sh down' when done!"
}

# --- Destroy ---
cmd_destroy() {
    preflight; load
    echo "⚠️  This will DELETE all resources including ALL snapshots!"
    read -p "Type 'destroy' to confirm: " confirm
    [ "$confirm" != "destroy" ] && die "Aborted."

    # Terminate instance
    [ -n "${INSTANCE_ID:-}" ] && {
        info "Terminating instance..."
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || sleep 30
    }

    # Delete all shazam snapshots
    local snaps=$(aws ec2 describe-snapshots --owner-ids self \
        --filters "Name=tag-key,Values=$TAG_PREFIX-vm" "Name=tag-key,Values=$TAG_PREFIX-role" \
        --query 'Snapshots[*].SnapshotId' --output text 2>/dev/null)
    for snap in $snaps; do
        info "Deleting snapshot $snap..."
        aws ec2 delete-snapshot --snapshot-id "$snap" 2>/dev/null || true
    done

    # Delete orphan volumes
    local vols=$(aws ec2 describe-volumes \
        --filters "Name=tag-key,Values=$TAG_PREFIX-label" "Name=status,Values=available" \
        --query 'Volumes[*].VolumeId' --output text 2>/dev/null)
    for vol in $vols; do
        info "Deleting volume $vol..."
        aws ec2 delete-volume --volume-id "$vol" 2>/dev/null || true
    done

    # SG + Key
    [ -n "${SG_ID:-}" ] && { aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null || true; }
    [ -n "${KEY_NAME:-}" ] && { aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true; }

    rm -f "$STATE"
    info "All resources destroyed."
}

# --- Main ---
case "${1:-up}" in
    up)       cmd_up "${2:-}" ;;
    down)     cmd_down ;;
    destroy)  cmd_destroy ;;
    ssh)      cmd_ssh ;;
    winssh)   cmd_winssh "${2:-}" ;;
    status)   cmd_status ;;
    cost)     cmd_cost ;;
    snapshot) cmd_snapshot "${2:-}" ;;
    clone)    cmd_clone "${2:-}" "${3:-}" ;;
    install)  cmd_install "${2:-}" ;;
    list)     cmd_list ;;
    *)        echo "Usage: bash shazam.sh [up|down|destroy|ssh|winssh|status|cost|snapshot|clone|install|list] [args]"; exit 1 ;;
esac
