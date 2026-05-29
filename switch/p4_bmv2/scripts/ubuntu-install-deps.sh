#!/bin/bash
# Ubuntu 22.04/24.04 - install BMv2 + p4c deps (run with sudo)
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Usage: sudo bash scripts/ubuntu-install-deps.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  git cmake g++ pkg-config libgoogle-perftools-dev \
  automake libtool libgc-dev libjudy-dev libboost-all-dev \
  libssl-dev libffi-dev python3 python3-pip \
  iproute2 tcpdump dos2unix

pip3 install --break-system-packages scapy 2>/dev/null || pip3 install scapy

if command -v p4c >/dev/null && command -v simple_switch >/dev/null; then
  echo "p4c and simple_switch already installed, skip compile."
  exit 0
fi

echo "p4c/simple_switch not found."
echo "If you use p4dev VM, activate it: source ~/p4dev-python-venv/bin/activate"
echo "Or compile from source (see DEPLOY_UBUNTU.md)."
