#!/bin/bash
set -euo pipefail
# shazam.sh - One-command setup for Windows Server 2022 dev environment on AWS metal spot
# Usage: bash shazam.sh [up|down|ssh|status]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SCRIPT_DIR"
REGION="${AWS_DEFAULT_REGION:-}"
VOL_ID=""
KEY_NAME="ett8u-key"
KEY_FILE="$HOME/.ssh/$KEY_NAME"
SG_NAME="metal-spot4win"
INSTANCE_TYPE="c5.metal"

# --- Helpers ---
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $1"; }

check_aws() {
    command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    aws sts get-caller-identity > /dev/null 2>&1 || die "AWS CLI not configured. Run: aws configure"
    if [ -z "$REGION" ]; then
        REGION=$(aws configure get region 2>/dev/null || true)
        [ -z "$REGION" ] && die "No AWS region set. Run: aws configure set region ap-south-1"
    fi
    info "AWS region: $REGION"
}

load_state() {
    [ -f "$STATE_DIR/.shazam-state" ] && source "$STATE_DIR/.shazam-state"
}

save_state() {
    cat > "$STATE_DIR/.shazam-state" << EOF
VOL_ID="$VOL_ID"
INSTANCE_ID="$INSTANCE_ID"
PUBLIC_IP="$PUBLIC_IP"
REGION="$REGION"
KEY_NAME="$KEY_NAME"
SG_ID="$SG_ID"
SUBNET_ID="$SUBNET_ID"
EOF
}

# --- Commands ---
cmd_up() {
    check_aws
    load_state

    # SSH key
    if [ ! -f "$KEY_FILE" ]; then
        info "Generating SSH key..."
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -q
        aws ec2 import-key-pair --region "$REGION" --key-name "$KEY_NAME" \
            --public-key-material fileb://"$KEY_FILE.pub" 2>/dev/null || true
    fi

    # Security group
    if [ -z "${SG_ID:-}" ]; then
        info "Creating security group..."
        VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
        SG_ID=$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME" --description "metal-spot4win" --vpc-id "$VPC_ID" --query 'GroupId' --output text 2>/dev/null || \
            aws ec2 describe-security-groups --region "$REGION" --group-names "$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)
        for port in 22 2222 3389 5900; do
            aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port $port --cidr 0.0.0.0/0 2>/dev/null || true
        done
    fi

    # Subnet
    if [ -z "${SUBNET_ID:-}" ]; then
        SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
    fi
    AZ=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)

    # EBS volume
    if [ -z "${VOL_ID:-}" ]; then
        info "Creating 250GB persistent EBS volume..."
        VOL_ID=$(aws ec2 create-volume --region "$REGION" --availability-zone "$AZ" --size 250 --volume-type gp3 \
            --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=metal-spot4win}]' --query 'VolumeId' --output text)
        aws ec2 wait volume-available --region "$REGION" --volume-ids "$VOL_ID"
        info "Volume: $VOL_ID (needs one-time partitioning — see README)"
    fi

    # AMI
    AMI=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

    # Launch spot instance
    info "Launching $INSTANCE_TYPE spot instance..."
    USERDATA=$(cat "$SCRIPT_DIR/launch-metal-spot.sh" | sed -n '/^USERDATA=/,/^CLOUDINIT$/p' | head -n -1 | tail -n +2)
    # Inline the cloud-init from launch script
    INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
        --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
        --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}' \
        --associate-public-ip-address \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30}}]' \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=metal-spot4win}]' \
        --user-data file://<(cat "$SCRIPT_DIR/launch-metal-spot.sh" | sed -n '/^USERDATA=\$(cat/,/^)$/{ /^USERDATA/d; /^)$/d; p; }') \
        --query 'Instances[0].InstanceId' --output text 2>/dev/null) || die "Failed to launch. Check spot vCPU quota (need 96 for $INSTANCE_TYPE)."

    info "Instance: $INSTANCE_ID — waiting..."
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

    PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    info "Attaching EBS volume..."
    aws ec2 attach-volume --region "$REGION" --volume-id "$VOL_ID" --instance-id "$INSTANCE_ID" --device /dev/xvdf
    aws ec2 wait volume-in-use --region "$REGION" --volume-ids "$VOL_ID"

    save_state

    info "Waiting for cloud-init..."
    sleep 30
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" "ubuntu@$PUBLIC_IP" "df -h /opt /data 2>/dev/null && echo READY" || true

    echo ""
    echo "============================================"
    echo "  Instance: $INSTANCE_ID"
    echo "  IP:       $PUBLIC_IP"
    echo "  SSH:      ssh -i $KEY_FILE ubuntu@$PUBLIC_IP"
    echo "  Win SSH:  ssh -p 2222 Administrator@$PUBLIC_IP"
    echo "  Win RDP:  $PUBLIC_IP:3389"
    echo "============================================"
    echo ""
    echo "To tear down: bash shazam.sh down"
}

cmd_down() {
    load_state
    check_aws
    [ -z "${INSTANCE_ID:-}" ] && die "No instance found. Nothing to tear down."

    info "Terminating instance $INSTANCE_ID..."
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
    info "Instance terminated. EBS volume $VOL_ID preserved."
    echo ""
    echo "To delete ALL resources (including EBS): bash shazam.sh destroy"

    # Clear instance state but keep volume
    INSTANCE_ID=""
    PUBLIC_IP=""
    save_state
}

cmd_destroy() {
    load_state
    check_aws

    if [ -n "${INSTANCE_ID:-}" ]; then
        info "Terminating instance..."
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" 2>/dev/null || true
    fi

    if [ -n "${VOL_ID:-}" ]; then
        info "Deleting EBS volume $VOL_ID..."
        aws ec2 delete-volume --region "$REGION" --volume-id "$VOL_ID" 2>/dev/null || echo "Volume may still be attached, try again later."
    fi

    if [ -n "${SG_ID:-}" ]; then
        info "Deleting security group..."
        aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || true
    fi

    rm -f "$STATE_DIR/.shazam-state"
    info "All resources destroyed."
}

cmd_ssh() {
    load_state
    [ -z "${PUBLIC_IP:-}" ] && die "No instance running. Run: bash shazam.sh up"
    ssh -i "$KEY_FILE" "ubuntu@$PUBLIC_IP"
}

cmd_status() {
    load_state
    check_aws
    if [ -z "${INSTANCE_ID:-}" ]; then
        echo "No instance. Run: bash shazam.sh up"
    else
        STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
        echo "Instance: $INSTANCE_ID ($STATE)"
        echo "IP:       ${PUBLIC_IP:-none}"
        echo "Volume:   ${VOL_ID:-none}"
        echo "Region:   $REGION"
    fi
}

# --- Main ---
case "${1:-up}" in
    up)      cmd_up ;;
    down)    cmd_down ;;
    destroy) cmd_destroy ;;
    ssh)     cmd_ssh ;;
    status)  cmd_status ;;
    *)       echo "Usage: bash shazam.sh [up|down|destroy|ssh|status]"; exit 1 ;;
esac
