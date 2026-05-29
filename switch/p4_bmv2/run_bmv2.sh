#!/bin/bash
# BMv2 前台启动 simple_switch（调试时用；后台用 scripts/start_switch.sh）
# 编译 P4 并绑定 veth-switch/h1/h2 到 port 0/1/2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${ROOT}/build"
PCAP="${BUILD}/pcap"
P4C="${P4C:-p4c}"

mkdir -p "$BUILD" "$PCAP"

echo "==> compile"
"$P4C" --target bmv2 --arch v1model -o "$BUILD" "$ROOT/fisslock_bmv2.p4"

JSON="${BUILD}/fisslock_bmv2.json"
[[ -f "$JSON" ]] || JSON="${BUILD}/fisslock_bmv2/fisslock_bmv2.json"

echo "==> veth"
sudo bash "$ROOT/scripts/setup_veth.sh"

echo "==> simple_switch (foreground)"
echo "    JSON=$JSON"
echo "    other terminal: simple_switch_CLI < $ROOT/setup/multicast.txt"
echo "    test: sudo python3 $ROOT/test/test_paths.py --iface veth-inject --pcap-dir $PCAP"

exec sudo simple_switch \
  --log-console \
  -i 0@veth-switch \
  -i 1@veth-h1 \
  -i 2@veth-h2 \
  --pcap "$PCAP" \
  "$JSON"
