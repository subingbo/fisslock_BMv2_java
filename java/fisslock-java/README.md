# FissLock Java（业务接 Sidecar）

阶段 **0.1**：在已有 **BMv2 + veth** 环境上，用 Java 调用 FissLock 锁（经 gRPC Sidecar 注入锁包）。

> 完整 `lib/` + DPDK + Tofino 尚未接入；见 [docs/JAVA_INTEGRATION_zh.md](../../docs/JAVA_INTEGRATION_zh.md)。

## 架构

```
Java 业务 (BasicExample)  --gRPC-->  LockSidecarMain (sudo)
                                           |
                              bmv2_try_acquire.py (Scapy)
                                           |
                                      veth-inject → simple_switch (BMv2)
```

## 构建（需 JDK 17+、Maven）

```bash
cd java/fisslock-java
mvn -q package
# 产物: target/fisslock-java-0.1.0-SNAPSHOT.jar
```

## 部署到虚拟机（推荐）

从 Windows 同步：

```powershell
scp -r D:\fisslock\java\fisslock-java subingbo@192.168.43.110:~/fisslock/java/
```

VM 上：

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/fix-crlf.sh
bash scripts/vm-setup.sh
```

完整三终端步骤见 **[docs/OPERATIONS_MANUAL_zh.md](../../docs/OPERATIONS_MANUAL_zh.md)**。

## 运行（在 p4dev VM 上）

终端 1 — 交换机（若未启动）：

```bash
cd ~/fisslock/switch/p4_bmv2
bash scripts/stop_switch.sh
sudo rm -f build/pcap/*.pcap
RESTART=1 bash scripts/start_switch.sh
```

终端 2 — Sidecar（**root**，默认 Python/Scapy 后端）：

```bash
cd ~/fisslock/java/fisslock-java
mvn -q package -DskipTests
bash scripts/vm-run-sidecar.sh
```

联调前可单独测 Scapy 助手：

```bash
bash scripts/vm-test-python-backend.sh   # 期望 stdout JSON granted:true
```

终端 3 — 业务 Java（无需 root）：

```bash
cd ~/fisslock/java/fisslock-java
mvn -q exec:java -Dexec.mainClass=com.fisslock.example.BasicExample -Dexec.args=1
```

## API 示例

```java
try (FissLockClient client = FissLockClient.connectLocal(1)) {
  FissLock lock = client.getLock("order:1001");
  if (lock.tryLock()) {
    try {
      // 临界区
    } finally {
      lock.unlock();
    }
  }
}
```

## 依赖

- Ubuntu: `sudo apt-get install -y libpcap-dev openjdk-17-jdk maven`
- 与 `test_paths.py` 相同：交换机已运行、`mgrp(299)` 已配置。
