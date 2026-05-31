#!/bin/bash
# ============================================================================
# FissLock BMv2 — 一键后台启动交换机
# ============================================================================
# 步骤: ① p4c 编译 fisslock_bmv2.p4 → build/fisslock_bmv2.json
#       ② setup_veth.sh 创建 veth-switch / veth-h1 / veth-h2 / veth-inject
#       ③ simple_switch 加载 JSON，port 0/1/2 接三根 veth
#       ④ simple_switch_CLI 执行 setup/multicast.txt 灌组播表
# 测试: sudo python3 test/test_paths.py --iface veth-inject --pcap-dir build/pcap
# 文档: switch/LEARNING_zh.md, DEPLOY_UBUNTU.md
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build"
PCAP="${BUILD}/pcap"
LOG="${BUILD}/switch.log"
PIDFILE="${BUILD}/simple_switch.pid"
JSON="${BUILD}/fisslock_bmv2.json"

# Load p4dev / system p4c into PATH
# shellcheck disable=SC1091
source "$ROOT/scripts/activate_p4env.sh" || true

# Explicit fallback (p4dev VM: p4c in tutorials, BMv2 in /usr/local/bin)
for _p4c in \
  "${P4C:-}" \
  "$HOME/tutorials/p4c-stable/build/p4c" \
  "$HOME/tutorials/p4c/build/p4c" \
  "$(command -v p4c 2>/dev/null)" \
  ; do
  [[ -n "$_p4c" && -x "$_p4c" ]] && export P4C="$_p4c" && break
done

P4C="${P4C:?p4c not found; export P4C=/path/to/p4c}"
SS="${SS:-$(command -v simple_switch)}"
CLI="${CLI:-$(command -v simple_switch_CLI)}"
export PATH="/usr/local/bin:$(dirname "$P4C"):${PATH}"

mkdir -p "$BUILD" "$PCAP"

echo "==> compile P4 (using $P4C)"
if [[ ! -f "$JSON" ]] || [[ "${SKIP_P4_COMPILE:-0}" != "1" ]]; then
  "$P4C" --target bmv2 --arch v1model -o "$BUILD" "$ROOT/fisslock_bmv2.p4"
fi
[[ -f "$JSON" ]] || JSON="${BUILD}/fisslock_bmv2/fisslock_bmv2.json"
if [[ ! -f "$JSON" ]]; then
  echo "JSON not found at $JSON"
  echo "Install p4c or compile elsewhere and copy json into build/"
  exit 1
fi

echo "==> setup veth"
sudo bash "$ROOT/scripts/setup_veth.sh"

_running() {
  pgrep -f "simple_switch.*fisslock_bmv2.json" >/dev/null 2>&1
}

if _running; then
  if [[ "${RESTART:-0}" == "1" ]]; then
    echo "==> RESTART=1: stop old simple_switch"
    bash "$ROOT/scripts/stop_switch.sh"
    sleep 1
  else
    echo "simple_switch already running (pid $(cat "$PIDFILE"))"
    echo "  若 build/pcap 为空或删过 pcap，请: RESTART=1 bash scripts/start_switch.sh"
    exit 0
  fi
fi

echo "==> start simple_switch"
sudo nohup "$SS" \
  --log-console \
  -i 0@veth-switch \
  -i 1@veth-h1 \
  -i 2@veth-h2 \
  --pcap "$PCAP" \
  "$JSON" \
  >"$LOG" 2>&1 &
echo $! | sudo tee "$PIDFILE" >/dev/null
sleep 2

echo "==> configure multicast"
if grep -vE '^\s*#|^\s*$' "$ROOT/setup/multicast.txt" | sudo "$CLI" >>"$LOG" 2>&1; then
  if grep -q 'mgrp(299)' "$LOG" 2>/dev/null || echo mc_dump | sudo "$CLI" 2>/dev/null | grep -q 'mgrp(299)'; then
    echo "  multicast: mgrp 299 OK"
  else
    echo "  [warn] 未在日志中看到 mgrp(299)，请: bash scripts/apply_multicast.sh"
  fi
else
  echo "  [warn] multicast CLI failed (Ubuntu: sudo apt-get install -y python3-thrift)"
  echo "  run: bash scripts/apply_multicast.sh"
fi

echo ""
echo "Started. pid=$(cat "$PIDFILE")"
echo "  组播已在启动时灌表，一般无需再 bash scripts/apply_multicast.sh"
echo "  log:  $LOG"
echo "  pcap: $PCAP"
echo "  test: sudo python3 $ROOT/test/test_paths.py --iface veth-inject --pcap-dir $PCAP"
echo "  stop: bash $ROOT/scripts/stop_switch.sh"
