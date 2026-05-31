#!/bin/bash
# 先停再起（清空 pcap 后必须用此脚本，不要只 rm pcap）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export P4C="${P4C:-$HOME/tutorials/p4c-stable/build/p4c}"
export PATH="$(dirname "$P4C"):/usr/local/bin:${PATH}"
bash "$ROOT/scripts/stop_switch.sh"
sleep 1
RESTART=1 bash "$ROOT/scripts/start_switch.sh"
