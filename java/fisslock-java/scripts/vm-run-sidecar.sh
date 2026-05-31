#!/bin/bash
# 启动锁 Sidecar（需 root；先确保 BMv2 已 start_switch）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAR="$ROOT/target/fisslock-java-0.1.0-SNAPSHOT.jar"
SEND_IFACE="${FISSLOCK_SEND_IFACE:-veth-inject}"
PCAP_DIR="${FISSLOCK_PCAP_DIR:-$HOME/fisslock/switch/p4_bmv2/build/pcap}"
PORT="${FISSLOCK_GRPC_PORT:-50051}"
MACHINE_ID="${FISSLOCK_MACHINE_ID:-1}"
TIMEOUT_MS="${FISSLOCK_TIMEOUT_MS:-3000}"
BACKEND="${FISSLOCK_BACKEND:-python}"
FISSLOCK_LIB_DIR="${FISSLOCK_LIB_DIR:-$HOME/fisslock/lib/bmv2}"
export LD_LIBRARY_PATH="${FISSLOCK_LIB_DIR}:${LD_LIBRARY_PATH:-}"
PYTHON="${FISSLOCK_PYTHON:-$HOME/tutorials/p4dev-python-venv/bin/python3}"
SCRIPT="${FISSLOCK_PYTHON_SCRIPT:-$ROOT/scripts/bmv2_try_acquire.py}"

[[ -f "$JAR" ]] || { echo "run vm-setup.sh first"; exit 1; }
[[ -d "$PCAP_DIR" ]] || { echo "pcap dir missing: $PCAP_DIR (start_switch first)"; exit 1; }
if [[ "$BACKEND" == "python" ]]; then
  [[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }
  [[ -x "$PYTHON" || -f "$PYTHON" ]] || { echo "python not found: $PYTHON"; exit 1; }
fi
if [[ "$BACKEND" == "lib" || "$BACKEND" == "native" ]]; then
  [[ -f "$FISSLOCK_LIB_DIR/libfisslock_bmv2.so" ]] || {
    echo "missing $FISSLOCK_LIB_DIR/libfisslock_bmv2.so — run: bash scripts/vm-build-lib.sh"
    exit 1
  }
fi

JAVA_OPTS=()
if [[ "$BACKEND" == "lib" || "$BACKEND" == "native" ]]; then
  JAVA_OPTS+=(-Djava.library.path="$FISSLOCK_LIB_DIR")
fi

echo "==> FissLock sidecar backend=$BACKEND send=$SEND_IFACE pcap=$PCAP_DIR port=$PORT"
export FISSLOCK_PCAP_DIR="$PCAP_DIR"
export FISSLOCK_BACKEND="$BACKEND"
export FISSLOCK_PYTHON="$PYTHON"
export FISSLOCK_PYTHON_SCRIPT="$SCRIPT"
export FISSLOCK_LIB_DIR
cd "$ROOT"
exec sudo -E java "${JAVA_OPTS[@]}" -jar "$JAR" \
  --backend "$BACKEND" \
  --send-iface "$SEND_IFACE" \
  --pcap-dir "$PCAP_DIR" \
  --python "$PYTHON" \
  --python-script "$SCRIPT" \
  --machine-id "$MACHINE_ID" \
  --port "$PORT" \
  --timeout-ms "$TIMEOUT_MS"
