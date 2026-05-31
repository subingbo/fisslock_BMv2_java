#!/bin/bash
# 联调前快速检查
set -eu
echo "==> simple_switch"
CNT=$(pgrep -cf 'simple_switch.*fisslock_bmv2' 2>/dev/null || echo 0)
if [ "$CNT" -eq 0 ] 2>/dev/null; then
  echo "  [WARN] switch not running"
elif [ "$CNT" -gt 1 ] 2>/dev/null; then
  echo "  [WARN] $CNT simple_switch instances — run: cd ~/fisslock/switch/p4_bmv2 && bash scripts/stop_switch.sh"
  pgrep -af 'simple_switch.*fisslock_bmv2' || true
else
  pgrep -af 'simple_switch.*fisslock_bmv2' || true
fi

echo "==> gRPC 50051"
ss -tlnp 2>/dev/null | grep 50051 || echo "  [WARN] sidecar not listening (run vm-run-sidecar.sh)"

echo "==> veth"
ip -br link show veth-inject veth-switch veth-h1 2>/dev/null || true

echo "==> quick python grant (optional)"
if [ -f "$HOME/fisslock/switch/p4_bmv2/test/test_paths.py" ]; then
  PY="${HOME}/tutorials/p4dev-python-venv/bin/python3"
  if [ -x "$PY" ]; then
    sudo "$PY" "$HOME/fisslock/switch/p4_bmv2/test/test_paths.py" \
      --iface veth-inject --only state --pcap-dir "$HOME/fisslock/switch/p4_bmv2/build/pcap" \
      | tail -3 || true
  fi
fi
