#!/bin/bash
# setup-wsl.sh - Configure WSL2 Ubuntu for development
set -e

echo "=== Updating packages ==="
apt-get update && apt-get upgrade -y

echo "=== Installing dev tools ==="
apt-get install -y \
  build-essential git curl wget unzip \
  python3 python3-pip python3-venv \
  nodejs npm \
  jq tree htop

echo "=== Installing AWS CLI v2 ==="
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

echo "=== Configuring git ==="
git config --global init.defaultBranch main

echo "=== Done ==="
echo "WSL2 Ubuntu configured for development"
