#!/bin/bash
# 业务示例（无需 root；Sidecar 须已在另一终端运行）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MACHINE_ID="${1:-1}"

mvn -q exec:java \
  -Dexec.mainClass=com.fisslock.example.BasicExample \
  -Dexec.args="$MACHINE_ID"
