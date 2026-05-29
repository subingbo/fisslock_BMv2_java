#!/bin/bash
# 停止 start_switch.sh 启动的后台 simple_switch（读 build/simple_switch.pid）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="${ROOT}/build/simple_switch.pid"
if [[ -f "$PIDFILE" ]]; then
  sudo kill "$(cat "$PIDFILE")" 2>/dev/null || true
  sudo rm -f "$PIDFILE"
  echo "stopped"
else
  sudo pkill -f "simple_switch.*fisslock_bmv2" 2>/dev/null || echo "not running"
fi
