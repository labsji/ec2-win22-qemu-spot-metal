#!/bin/bash
set -euo pipefail

REGION="ap-south-1"
AMI="ami-05d2d839d4f73aafb"  # Ubuntu 24.04
KEY="ett8u-key"
SG="sg-08b8f43abbfcd93df"
SUBNET="subnet-0e8e520871a0c51b2"
VOL_ID="vol-049250470b06c4ba7"
INSTANCE_TYPE="${1:-c5.metal}"

# Cloud-init userdata: mount EBS partitions as /var /usr /opt /data early in boot
USERDATA=$(cat <<'CLOUDINIT'
#!/bin/bash
# Wait for the EBS volume device to appear
for i in $(seq 1 30); do
  DEV=""
  for d in /dev/nvme1n1 /dev/nvme2n1 /dev/xvdf; do
    if [ -b "${d}p1" ] 2>/dev/null; then DEV="$d"; S="p"; break; fi
    if [ -b "${d}1" ] 2>/dev/null; then DEV="$d"; S=""; break; fi
  done
  [ -n "$DEV" ] && break
  sleep 2
done
[ -z "$DEV" ] && exit 1

# Mount by label into system paths
mount LABEL=var /var
mount LABEL=usr /usr
mount LABEL=opt /opt
mkdir -p /data
mount LABEL=data /data

# Add to fstab for persistence across reboots
grep -q LABEL=var /etc/fstab || cat >> /etc/fstab <<FSTAB
LABEL=var /var ext4 defaults,nofail 0 2
LABEL=usr /usr ext4 defaults,nofail 0 2
LABEL=opt /opt ext4 defaults,nofail 0 2
LABEL=data /data ext4 defaults,nofail 0 2
FSTAB

# Restart services that depend on /var
systemctl daemon-reexec
systemctl restart libvirtd.socket
CLOUDINIT
)

echo "Requesting c5.metal spot instance..."
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY" --security-group-ids "$SG" --subnet-id "$SUBNET" \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}' \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=metal-spot4win}]' \
  --user-data "$USERDATA" \
  --query 'Instances[0].InstanceId' --output text)

echo "Instance: $INSTANCE_ID — waiting for running state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Public IP: $PUBLIC_IP"

echo "Attaching volume $VOL_ID..."
aws ec2 attach-volume --region "$REGION" \
  --volume-id "$VOL_ID" --instance-id "$INSTANCE_ID" --device /dev/xvdf
aws ec2 wait volume-in-use --volume-ids "$VOL_ID" --region "$REGION"

echo "Waiting for cloud-init to mount volumes..."
sleep 30

echo "Verifying mounts..."
ssh -o StrictHostKeyChecking=no -i ~/.ssh/ett8u-key "ubuntu@$PUBLIC_IP" \
  "df -h /var /usr /opt /data && virsh version 2>/dev/null && echo 'All good.'"

echo "Done. Instance $INSTANCE_ID at $PUBLIC_IP"
echo "$INSTANCE_ID" > ~/metal-spot4win/.instance-id
echo "$PUBLIC_IP" > ~/metal-spot4win/.instance-ip
