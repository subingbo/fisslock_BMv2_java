# Java 业务接入 FissLock

架构与进程总览见 **[ARCHITECTURE_AND_RUNBOOK_zh.md](./ARCHITECTURE_AND_RUNBOOK_zh.md)**。

## 目标与阶段

| 阶段 | 内容 | 状态 |
|------|------|------|
| **0.1（当前）** | Java API + gRPC Sidecar + BMv2（默认 **Python/Scapy** 助手发包读 pcap） | 仓库 `java/fisslock-java/` |
| **0.2** | Sidecar **JNI → `lib/lock.cc`**（BMv2 pcap 网络层，无 DPDK） | `FISSLOCK_BACKEND=lib`，见 [LIB_BMV2_INTEGRATION_zh.md](./LIB_BMV2_INTEGRATION_zh.md) |
| **1.0** | Tofino + 控制面 `lock_register` + 生产部署 | 需硬件 |

当前 **不需要** `baseline/`；需要 **`switch/p4_bmv2`（或未来 Tofino `switch/p4`）** 与 VM 上的 veth。

---

## 为什么用 Sidecar

**详细说明**（「发包」是什么、为何业务 JVM 不直接 root 发包、与 `lib` 锁管理的区别）见 [ARCHITECTURE_AND_RUNBOOK_zh.md §2](./ARCHITECTURE_AND_RUNBOOK_zh.md#2-sidecar-是什么)（小节 2.1–2.5）。

摘要：

- Sidecar **不是**完整锁管理器（队列/agent 在 C++ `lib/`）；0.1 里它是 **锁协议的网络适配层**（发 ACQUIRE、读 GRANT、发 FREE）。
- 向 `veth-inject` 注入原始锁包通常要 **sudo / libpcap / Scapy**；业务示例用 **普通用户** 跑，发包放在 **sudo 的 Sidecar** 里。
- Java 业务 **不装 DPDK**、不绑核；Sidecar 以 **root** 调 `bmv2_try_acquire.py`（与 `test_paths.py` 同逻辑）。
- 可选 `FISSLOCK_BACKEND=pcap`（Pcap4j，部分 VM 不稳定）。
- 0.2 可把 Sidecar 后端换成 **JNI → `lib`**，**Java API 可不变**。

---

## 目录

```
java/fisslock-java/
├── src/main/proto/fisslock/v1/lock.proto   # gRPC 定义
├── src/main/java/com/fisslock/
│   ├── protocol/          # 17 字节锁包编解码（对齐 post.h）
│   ├── sidecar/           # LockSidecarMain、Bmv2PythonHelperBackend、Bmv2PcapLockBackend
│   └── scripts/           # bmv2_try_acquire.py、vm-run-sidecar.sh
│   ├── client/            # FissLockClient、FissLock（类 Redisson）
│   └── example/           # BasicExample
└── pom.xml
```

---

## 运行步骤（BMv2 VM）

见 **[OPERATIONS_MANUAL_zh.md](./OPERATIONS_MANUAL_zh.md)**（推荐）或 [java/fisslock-java/README.md](../java/fisslock-java/README.md)。

简要：

1. `RESTART=1 bash scripts/start_switch.sh`（`p4_bmv2`）
2. `bash scripts/vm-run-sidecar.sh`（默认 `FISSLOCK_BACKEND=python`）
3. 业务 `FissLockClient.connectLocal(machineId)` + `getLock().tryLock()`

---

## 与 Redisson 的差异

| 能力 | Redisson | 本 Java 层（0.1） |
|------|----------|-------------------|
| `lock` / `tryLock` / `unlock` | ✅ | ✅ |
| 可重入 | ✅ | ✅（ThreadLocal 本地计数） |
| 看门狗租约 | ✅ | ❌ 需自实现 |
| 共享锁二次 ACQUIRE 组播 | N/A | Sidecar 仅发单次 ACQUIRE；完整组播需 0.2 |
| 后端 | Redis | BMv2 交换机 |

---

## 演进：接上完整 `lib/`

**BMv2（已完成骨架）**：见 [LIB_BMV2_INTEGRATION_zh.md](./LIB_BMV2_INTEGRATION_zh.md) — `lib/bmv2/` + `vm-build-lib.sh` + `FISSLOCK_BACKEND=lib`。

**论文全栈（待做）**：

1. 链真实 `lib/net.cc` + DPDK（替换 `lib/bmv2/bmv2_net.cc`）。
2. 多机 `env_setup` + `lock_init` RPC（`switch/control`）。
3. 有 Tofino 时：数据面换 `switch/p4`。

---

## 常见问题

**Sidecar 启动失败 `interface not found`**  
→ 先 `bash scripts/setup_veth.sh`，确认 `ip link show veth-inject`。

**tryLock 一直 false / gRPC UNKNOWN**  
→ 交换机未运行或多实例 `simple_switch`；先 `bash scripts/vm-test-python-backend.sh` 确认 Scapy 能拿 GRANT；再启 Sidecar 看 `[python]` / `[backend] GRANT` 日志。

**Sidecar 默认后端**  
→ `FISSLOCK_BACKEND=python`（推荐）；`pcap` 为 Pcap4j fallback。

**Windows 上能编译吗？**  
→ `mvn package` 可编 Java；**运行 Sidecar 须在 Linux VM**（Pcap + veth）。
