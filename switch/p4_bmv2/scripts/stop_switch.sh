#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="${ROOT}/build/simple_switch.pid"

sudo pkill -f "simple_switch.*fisslock_bmv2.json" 2>/dev/null && echo "pkill simple_switch" || true
sleep 1
sudo pkill -f "simple_switch.*fisslock_bmv2.json" 2>/dev/null || true
if [ -f "$PIDFILE" ]; then
  sudo kill "$(cat "$PIDFILE")" 2>/dev/null || true
  sudo rm -f "$PIDFILE"
fi
sleep 1
CNT=$(pgrep -cf "simple_switch.*fisslock_bmv2.json" 2>/dev/null || echo 0)
if [ "$CNT" -gt 0 ] 2>/dev/null; then
  echo "warn: still $CNT simple_switch (run stop again or: sudo pkill -f simple_switch)"
else
  echo "stopped"
fi
