#!/bin/bash
# 从 Windows 拷贝后若报 set: pipefail: invalid option，先运行本脚本
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
for f in "$ROOT"/*.sh; do
  sed -i 's/\r$//' "$f"
done
chmod +x "$ROOT"/*.sh
echo "==> fixed CRLF in $ROOT/*.sh"
