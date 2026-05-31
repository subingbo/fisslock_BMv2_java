#!/bin/bash
# 双线程抢锁（Sidecar: FISSLOCK_BACKEND=lib；交换机须已 start_switch）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOLD_SEC="${1:-5}"
WAITER_DELAY_MS="${2:-500}"

if [[ ! -f src/main/java/com/fisslock/example/ContentionExample.java ]]; then
  echo "missing ContentionExample.java — sync java/fisslock-java from dev machine"
  exit 1
fi

exec mvn -q -Pcontention exec:java -Dexec.args="${HOLD_SEC} ${WAITER_DELAY_MS}"
