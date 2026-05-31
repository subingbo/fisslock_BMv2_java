#!/bin/bash
# 不经过 Java/gRPC，直接测 Scapy 助手（与 test_paths 同路径）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${FISSLOCK_PYTHON:-$HOME/tutorials/p4dev-python-venv/bin/python3}"
SCRIPT="$ROOT/scripts/bmv2_try_acquire.py"
PCAP_DIR="${FISSLOCK_PCAP_DIR:-$HOME/fisslock/switch/p4_bmv2/build/pcap}"
IFACE="${FISSLOCK_SEND_IFACE:-veth-inject}"

[[ -f "$SCRIPT" ]] || { echo "missing script"; exit 1; }
echo "==> try_acquire lock_id=1 (order:1001 mapping)"
sudo "$PYTHON" "$SCRIPT" try_acquire \
  --iface "$IFACE" \
  --pcap-dir "$PCAP_DIR" \
  --lock-id 1 \
  --machine-id 1 \
  --timeout 3
