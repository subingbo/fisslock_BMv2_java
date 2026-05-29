#!/bin/bash
# 创建 BMv2 虚拟网线对（需 root）：
#   veth-switch <-> veth-inject（port0，测试发包口）
#   veth-switch/h1/h2 等见脚本内 create_pair 调用
set -euo pipefail

create_pair() {
  local a=$1 b=$2
  if ip link show "$a" &>/dev/null; then
    echo "  exists: $a <-> $b"
  else
    ip link add "$a" type veth peer name "$b"
    echo "  created: $a <-> $b"
  fi
  ip link set "$a" up
  ip link set "$b" up
}

echo "==> veth pairs for simple_switch"
create_pair veth-switch veth-inject
create_pair veth-h1     veth-host1
create_pair veth-h2     veth-host2

echo "==> done"
echo "    inject tests on: veth-inject"
echo "    sniff host1 on:  veth-host1"
echo "    sniff host2 on:  veth-host2"
