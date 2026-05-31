#!/bin/bash
# 在 p4dev VM 上首次安装 Java Sidecar 依赖并编译
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 修正 Windows scp 带来的 CRLF
bash "$ROOT/scripts/fix-crlf.sh"

echo "==> apt packages (openjdk 17, maven, libpcap)"
sudo apt-get update -qq
sudo apt-get install -y openjdk-17-jdk maven libpcap-dev

echo "==> mvn package"
mvn -q package -DskipTests

JAR="$ROOT/target/fisslock-java-0.1.0-SNAPSHOT.jar"
if [[ ! -f "$JAR" ]]; then
  echo "JAR not found: $JAR"
  exit 1
fi
chmod +x "$ROOT/scripts/"*.sh 2>/dev/null || true
echo "==> OK: $JAR"
echo "Next:"
echo "  1) cd ~/fisslock/switch/p4_bmv2 && RESTART=1 bash scripts/start_switch.sh"
echo "  2) bash $ROOT/scripts/vm-run-sidecar.sh"
echo "  3) bash $ROOT/scripts/vm-run-example.sh 1"
