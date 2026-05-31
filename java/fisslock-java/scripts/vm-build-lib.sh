#!/bin/bash
# 编译 libfisslock_bmv2.so（C++ lib/lock.cc + BMv2 pcap，无 DPDK）
set -eu
# scripts/ -> fisslock-java/ -> java/ -> fisslock/（仓库根）
FISSLOCK_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BMV2_LIB="$FISSLOCK_ROOT/lib/bmv2"
JAVA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
if [[ ! -d "$JAVA_HOME/include" ]]; then
  JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(which javac)")")")"
fi

echo "==> build libfisslock_bmv2.so (JAVA_HOME=$JAVA_HOME)"
echo "    FISSLOCK_ROOT=$FISSLOCK_ROOT"
[[ -d "$BMV2_LIB" ]] || {
  echo "missing $BMV2_LIB — scp from Windows: scp -r .../lib/bmv2 user@host:~/fisslock/lib/"
  exit 1
}
cd "$BMV2_LIB"
make clean
make JAVA_HOME="$JAVA_HOME" all

echo "==> mvn package (Java sidecar)"
cd "$JAVA_ROOT"
mvn -q package -DskipTests

echo "==> OK"
echo "Run Sidecar with C++ lib backend:"
echo "  export LD_LIBRARY_PATH=$BMV2_LIB:\$LD_LIBRARY_PATH"
echo "  export FISSLOCK_BACKEND=lib"
echo "  bash scripts/vm-run-sidecar.sh"
