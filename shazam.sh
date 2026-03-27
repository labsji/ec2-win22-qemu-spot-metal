#!/bin/bash
set -euo pipefail
# shazam.sh - One-command Windows dev environment on AWS metal spot
# Designed for AWS CloudShell (credentials and region are automatic)
#
# Usage:
#   bash shazam.sh          # launch (or resume)
#   bash shazam.sh down     # terminate instance, keep data
#   bash shazam.sh destroy  # delete EVERYTHING (EBS, SG, key)
#   bash shazam.sh ssh      # SSH into Linux host
#   bash shazam.sh winssh   # SSH into Windows VM
#   bash shazam.sh status   # show current state
#   bash shazam.sh cost     # show estimated running cost

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$SCRIPT_DIR/.shazam-state"
INSTANCE_TYPE="c5.metal"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "➡️  $1"; }
warn() { echo "⚠️  $1"; }

# --- Preflight ---
preflight() {
    command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Are you in AWS CloudShell?"
    aws sts get-caller-identity > /dev/null 2>&1 || die "AWS credentials not configured. Use AWS CloudShell (console.aws.amazon.com → CloudShell icon)."
    REGION=$(aws configure get region 2>/dev/null || echo "")
    [ -z "$REGION" ] && REGION=$AWS_DEFAULT_REGION
    [ -z "$REGION" ] && die "No region set. In CloudShell, region comes from the console URL. Or run: aws configure set region ap-south-1"
    export AWS_DEFAULT_REGION="$REGION"
    info "Region: $REGION"
}

load() { [ -f "$STATE" ] && source "$STATE" || true; }

save() {
    cat > "$STATE" << EOF
REGION="$REGION"
VOL_ID="${VOL_ID:-}"
SG_ID="${SG_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
KEY_NAME="${KEY_NAME:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
EOF
}

# --- Up ---
cmd_up() {
    preflight; load

    # SSH key (CloudShell home persists)
    KEY_NAME="${KEY_NAME:-shazam-$(whoami)}"
    KEY_FILE="$HOME/.ssh/$KEY_NAME"
    if [ ! -f "$KEY_FILE" ]; then
        info "Creating SSH key..."
        mkdir -p ~/.ssh && ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -q
        aws ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material fileb://"$KEY_FILE.pub" 2>/dev/null || true
    fi

    # Security group
    if [ -z "${SG_ID:-}" ]; then
        info "Creating security group..."
        VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
        SG_ID=$(aws ec2 create-security-group --group-name "shazam-$REGION" --description "metal-spot4win" --vpc-id "$VPC_ID" --query 'GroupId' --output text 2>/dev/null || \
            aws ec2 describe-security-groups --group-names "shazam-$REGION" --query 'SecurityGroups[0].GroupId' --output text)
        for port in 22 2222 3389 5900; do
            aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port $port --cidr 0.0.0.0/0 2>/dev/null || true
        done
    fi

    # Subnet + AZ
    if [ -z "${SUBNET_ID:-}" ]; then
        SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" --query 'Subnets[0].SubnetId' --output text)
    fi
    AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)

    # EBS volume
    if [ -z "${VOL_ID:-}" ]; then
        info "Creating 250GB persistent EBS volume in $AZ..."
        VOL_ID=$(aws ec2 create-volume --availability-zone "$AZ" --size 250 --volume-type gp3 \
            --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=shazam-$REGION}]" --query 'VolumeId' --output text)
        aws ec2 wait volume-available --volume-ids "$VOL_ID"
        warn "New volume — first launch will install QEMU and download ISOs (~30 min)"
    fi

    # Check if instance already running
    if [ -n "${INSTANCE_ID:-}" ]; then
        ISTATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
        if [ "$ISTATE" = "running" ]; then
            PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
            info "Already running: $INSTANCE_ID at $PUBLIC_IP"
            save; show_info; return
        fi
    fi

    # AMI
    AMI=$(aws ec2 describe-images --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

    # Cloud-init userdata
    USERDATA='#!/bin/bash
set -e
# Wait for EBS volume device
for i in $(seq 1 30); do
  for d in /dev/nvme1n1 /dev/nvme2n1 /dev/xvdf; do
    [ -b "$d" ] 2>/dev/null && DEV="$d" && break 2
  done; sleep 2
done
[ -z "${DEV:-}" ] && exit 1

# Check if volume has partitions (returning user) or is raw (fresh)
if blkid "${DEV}p1" >/dev/null 2>&1 || blkid "${DEV}1" >/dev/null 2>&1; then
  # --- EXISTING VOLUME: mount and auto-start ---
  # Old volumes have 4 partitions (var/usr/opt/data), new have 2 (opt/data)
  mount LABEL=opt /opt 2>/dev/null || true
  mkdir -p /data; mount LABEL=data /data 2>/dev/null || true
  # Legacy mounts for old 4-partition volumes (nofail — ok if missing)
  mount LABEL=var /var 2>/dev/null || true
  mount LABEL=usr /usr 2>/dev/null || true
  grep -q LABEL=opt /etc/fstab || cat >> /etc/fstab <<FSTAB
LABEL=opt /opt ext4 defaults,nofail 0 2
LABEL=data /data ext4 defaults,nofail 0 2
LABEL=var /var ext4 defaults,nofail 0 2
LABEL=usr /usr ext4 defaults,nofail 0 2
FSTAB
  [ -f /opt/winserver2022-auto.qcow2 ] && sudo -u ubuntu bash /opt/run-windows.sh 2>/dev/null || true
else
  # --- FRESH VOLUME: partition, install QEMU, download ISOs ---
  echo "Fresh volume detected. Partitioning $DEV..."
  parted -s "$DEV" mklabel gpt \
    mkpart opt ext4 1MiB 192GiB \
    mkpart data ext4 192GiB 100%
  sleep 2
  [ -b "${DEV}p1" ] && S="p" || S=""
  mkfs.ext4 -q -L opt "${DEV}${S}1"
  mkfs.ext4 -q -L data "${DEV}${S}2"
  mount "${DEV}${S}1" /opt
  mkdir -p /data; mount "${DEV}${S}2" /data
  cat >> /etc/fstab <<FSTAB
LABEL=opt /opt ext4 defaults,nofail 0 2
LABEL=data /data ext4 defaults,nofail 0 2
FSTAB

  # Install QEMU/KVM
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 qemu-utils ovmf libvirt-daemon-system sshpass socat dosfstools > /dev/null 2>&1

  # Download ISOs
  echo "Downloading Windows Server 2022 eval ISO (~5GB)..."
  curl -fsSL -o /data/win2022.iso "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US" || true
  echo "Downloading VirtIO drivers..."
  curl -fsSL -o /data/virtio-win.iso "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" || true

  touch /opt/.shazam-fresh-setup-done
  echo "Fresh setup complete."
fi'

    info "Launching $INSTANCE_TYPE spot instance..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
        --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}' \
        --associate-public-ip-address \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=shazam-$REGION}]" \
        --user-data "$USERDATA" \
        --query 'Instances[0].InstanceId' --output text 2>/dev/null) || true
    if [ -z "${INSTANCE_ID:-}" ] && [ "$INSTANCE_TYPE" = "c5.metal" ]; then
        INSTANCE_TYPE="c5n.metal"
        warn "c5.metal unavailable, trying $INSTANCE_TYPE..."
        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
            --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}' \
            --associate-public-ip-address \
            --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30}}]' \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=shazam-$REGION}]" \
            --user-data "$USERDATA" \
            --query 'Instances[0].InstanceId' --output text 2>/dev/null) || true
    fi
    [ -z "${INSTANCE_ID:-}" ] && die "Launch failed. Check spot vCPU quota (need 96 for metal). Request increase at: https://console.aws.amazon.com/servicequotas"

    info "Waiting for instance..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    info "Attaching EBS volume..."
    aws ec2 attach-volume --volume-id "$VOL_ID" --instance-id "$INSTANCE_ID" --device /dev/xvdf > /dev/null
    aws ec2 wait volume-in-use --volume-ids "$VOL_ID"

    save

    info "Waiting for cloud-init..."
    for i in $(seq 1 60); do
        STATUS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_FILE" "ubuntu@$PUBLIC_IP" "cloud-init status 2>/dev/null || echo running" 2>/dev/null)
        case "$STATUS" in *done*|*error*) break ;; esac
        sleep 10
    done

    # If fresh volume, copy install files and kick off Windows install
    if ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" "ubuntu@$PUBLIC_IP" "test -f /opt/.shazam-fresh-setup-done" 2>/dev/null; then
        info "Fresh volume — copying install files..."
        scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
            "$SCRIPT_DIR/install-windows.sh" "$SCRIPT_DIR/run-windows.sh" \
            "$SCRIPT_DIR/stop-windows.sh" "$SCRIPT_DIR/hw-id.conf" \
            "$SCRIPT_DIR/floppy.img" \
            "ubuntu@$PUBLIC_IP:/opt/"
        ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" "ubuntu@$PUBLIC_IP" "chmod +x /opt/install-windows.sh /opt/run-windows.sh"
        info "Starting Windows install (~30 min)..."
        ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" "ubuntu@$PUBLIC_IP" "nohup bash /opt/install-windows.sh > /tmp/win-install.log 2>&1 &"
        warn "Windows installing in background. Monitor: bash shazam.sh ssh then tail -f /tmp/win-install.log"
    elif ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_FILE" "ubuntu@$PUBLIC_IP" "test -f /opt/winserver2022-auto.qcow2" 2>/dev/null; then
        info "Existing Windows VM detected."
    else
        warn "Cloud-init may still be running. Check: bash shazam.sh ssh"
    fi

    show_info
}

show_info() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  🪟 Windows Dev Environment Ready        ║"
    echo "╠══════════════════════════════════════════╣"
    echo "  Instance:  $INSTANCE_ID"
    echo "  IP:        $PUBLIC_IP"
    echo "  Region:    $REGION"
    echo ""
    echo "  Linux SSH: bash shazam.sh ssh"
    echo "  Win SSH:   bash shazam.sh winssh"
    echo "  Win RDP:   $PUBLIC_IP:3389"
    echo ""
    echo "  💰 Cost:   ~\$1.50/hr (spot)"
    echo "  ⏹  Stop:   bash shazam.sh down"
    echo "╚══════════════════════════════════════════╝"
}

# --- Down ---
cmd_down() {
    preflight; load
    [ -z "${INSTANCE_ID:-}" ] && die "No instance running."
    info "Terminating $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null
    info "Instance terminated. EBS volume $VOL_ID preserved (no ongoing cost when detached)."
    warn "To delete ALL resources: bash shazam.sh destroy"
    INSTANCE_ID=""; PUBLIC_IP=""
    save
}

# --- Destroy ---
cmd_destroy() {
    preflight; load
    echo "⚠️  This will DELETE all resources including your persistent EBS volume!"
    echo "    Volume: ${VOL_ID:-none}"
    echo "    Region: $REGION"
    read -p "Type 'destroy' to confirm: " confirm
    [ "$confirm" != "destroy" ] && die "Aborted."

    [ -n "${INSTANCE_ID:-}" ] && {
        info "Terminating instance..."; aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || sleep 30
    }
    [ -n "${VOL_ID:-}" ] && { info "Deleting EBS volume..."; aws ec2 delete-volume --volume-id "$VOL_ID" 2>/dev/null || warn "Volume busy, try again later."; }
    [ -n "${SG_ID:-}" ] && { info "Deleting security group..."; aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null || true; }
    [ -n "${KEY_NAME:-}" ] && { info "Deleting key pair..."; aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true; }

    rm -f "$STATE"
    info "All resources destroyed. No ongoing AWS charges."
}

# --- SSH ---
cmd_ssh() {
    load
    [ -z "${PUBLIC_IP:-}" ] && die "No instance running. Run: bash shazam.sh"
    ssh -i "$HOME/.ssh/${KEY_NAME}" "ubuntu@$PUBLIC_IP"
}

cmd_winssh() {
    load
    [ -z "${PUBLIC_IP:-}" ] && die "No instance running. Run: bash shazam.sh"
    ssh -o StrictHostKeyChecking=no -p 2222 "Administrator@$PUBLIC_IP"
}

# --- Status ---
cmd_status() {
    preflight; load
    if [ -z "${INSTANCE_ID:-}" ]; then
        echo "No instance. Run: bash shazam.sh"
        [ -n "${VOL_ID:-}" ] && echo "EBS volume: $VOL_ID (preserved)"
    else
        ISTATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
        echo "Instance:  $INSTANCE_ID ($ISTATE)"
        echo "IP:        ${PUBLIC_IP:-none}"
        echo "Volume:    ${VOL_ID:-none}"
        echo "Region:    $REGION"
    fi
}

# --- Cost ---
cmd_cost() {
    preflight; load
    if [ -n "${INSTANCE_ID:-}" ]; then
        PRICE=$(aws ec2 describe-spot-price-history --instance-types "$INSTANCE_TYPE" \
            --product-descriptions "Linux/UNIX" --max-items 1 \
            --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null || echo "unknown")
        echo "Spot price: \$$PRICE/hr ($INSTANCE_TYPE in $REGION)"
        echo "EBS volume: \$0.08/GB/month = ~\$20/month for 250GB"
        echo ""
        warn "Remember to run 'bash shazam.sh down' when done!"
    else
        echo "No instance running. EBS volume cost: ~\$20/month (if exists)"
    fi
}

# --- Main ---
case "${1:-up}" in
    up)      cmd_up ;;
    down)    cmd_down ;;
    destroy) cmd_destroy ;;
    ssh)     cmd_ssh ;;
    winssh)  cmd_winssh ;;
    status)  cmd_status ;;
    cost)    cmd_cost ;;
    *)       echo "Usage: bash shazam.sh [up|down|destroy|ssh|winssh|status|cost]"; exit 1 ;;
esac
