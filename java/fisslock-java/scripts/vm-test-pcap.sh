#!/bin/bash
# 检查 sudo 环境是否有 libpcap（Sidecar 发/读包需要）
set -eu
echo "==> libpcap 库"
ldconfig -p 2>/dev/null | grep libpcap || true
ls -la /usr/lib/*/libpcap.so* 2>/dev/null || true

echo "==> 若 Sidecar 报 UNKNOWN / UnsatisfiedLinkError，执行:"
echo "    sudo apt-get install -y libpcap0.8 libpcap0.8-dev"
echo "    sudo ldconfig"
