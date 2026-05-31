#!/bin/bash
# 手动灌组播（仅当 start_switch 未成功灌表时使用）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${CLI:-simple_switch_CLI}"
MCAST_IN="$ROOT/setup/multicast.txt"
LOG="${ROOT}/build/mcast_cli.log"

mcast_ready() {
  echo mc_dump | sudo "$CLI" 2>/dev/null | grep -q 'mgrp(299)'
}

echo "==> apply multicast via $CLI"
if mcast_ready; then
  echo "==> multicast 已存在 (mgrp 299)，跳过（start_switch 已灌表则勿重复执行）"
  echo mc_dump | sudo "$CLI" 2>/dev/null | grep -A3 'mgrp(299)' || true
  exit 0
fi

if ! grep -vE '^\s*#|^\s*$' "$MCAST_IN" | sudo "$CLI" | tee "$LOG"; then
  echo "[FAIL] simple_switch_CLI 失败。Ubuntu 24.04: sudo apt-get install -y python3-thrift"
  exit 1
fi
if grep -qE 'INVALID_L1_HANDLE|Unknown syntax|\(ERROR\)' "$LOG"; then
  echo "[FAIL] 组播灌表有误，见 build/mcast_cli.log"
  echo "  先: bash scripts/stop_switch.sh && RESTART=1 bash scripts/start_switch.sh"
  echo "  再本脚本；勿在 start 成功后重复灌表"
  exit 1
fi
echo "==> multicast OK"
