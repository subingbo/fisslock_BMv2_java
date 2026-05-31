# FissLock 实验笔记：架构、进程与联调手册

本文是 **p4dev VM 上 BMv2 + Java Sidecar** 的总览笔记，便于复习「谁是谁、谁在跑、为什么这样设计」。  
细节命令见各专题文档。

---

## 1. 仓库里几块代码各干什么

| 目录 | 是否本次实验需要 | 作用 |
|------|------------------|------|
| `switch/p4_bmv2/` | **要** | BMv2 版 P4 数据面 + 脚本 + `test_paths.py` |
| `switch/p4/` + `switch/control/` | 否（要 Tofino） | 论文真机：Tofino P4 + BFRT 控制面 |
| `lib/` | 否（阶段 0.2+） | C++ 完整锁管理：DPDK、agent、等待队列 |
| `java/fisslock-java/` | **要** | Java API + gRPC Sidecar（阶段 0.1） |
| `baseline/` | 否 | NetLock / ParLock 对比实验，不是 FissLock 本体 |
| `experiments/` | 否 | 8 机压测、论文图表复现 |
| `tests/`（根目录） | 否 | 接 `lib` 的 C++ microbench，非 Java |

**结论**：当前路径 = **P4（BMv2）+ Python 验证 + Java Sidecar 演示**；不是完整论文栈。

---

## 2. Sidecar 是什么？

**Sidecar（边车）**：在业务进程 **旁边** 跑一个辅助服务，干业务不方便做的事。

在本项目中：

```text
┌─────────────────────┐     gRPC (:50051)     ┌─────────────────────────┐
│ Java 业务            │ ◄──────────────────► │ Lock Sidecar             │
│ FissLockClient       │                      │ LockSidecarMain (sudo)   │
│ 普通用户、无 DPDK     │                      │ sudo + Scapy 发包/读 pcap │
└─────────────────────┘                       └───────────┬─────────────┘
                                                          │
                                                          ▼
                                              veth-inject → simple_switch
```

| 角色 | 类比 |
|------|------|
| Java `FissLock` | 像 **Redisson** 的 `RLock` API |
| Sidecar | 像 **连 Redis 的客户端代理**，但后端是 **交换机锁协议** 不是 Redis |
| `simple_switch` | 像 **可编程交换机芯片**（软件仿真） |

Sidecar **不是**交换机，**不是** C++ `lib`，是 **Java 与交换机之间的适配层**。

### 2.1 先分清三件事（最容易混）

| 层次 | 做什么 | 在本仓库里谁负责 |
|------|--------|------------------|
| **交换机数据面** | 收到 ACQUIRE 后能否立刻 GRANT、指定 agent | P4 / `simple_switch` |
| **主机锁管理** | 等待队列、本机当 agent 后调度下一个、TRANSFER | C++ **`lib/lock.cc`**（阶段 0.2+） |
| **业务 API** | 应用里 `tryLock()` / `unlock()` | Java **`FissLock`** |
| **网络适配（0.1）** | 把 17 字节锁包塞进 `veth-inject`、判断有没有 GRANT | **Sidecar**（内部调 Scapy 脚本） |

因此：**需要 Sidecar，不是因为「锁管理只能写在 Sidecar」**——完整锁管理在 `lib`；Sidecar 是因为 **业务 Java 进程不适合直接干「root + 底层发包」**，在 0.1 里充当 **锁协议的网络驱动**。

### 2.2 「发包」在这里指什么？

不是 HTTP/RPC，而是向虚拟网卡 **`veth-inject`** 注入 **自编以太网帧**（内层 UDP + 17 字节锁载荷），与 `test_paths.py` 里 `sendp(...)` 相同。流量从 port0 进入 BMv2，由 P4 执行锁逻辑。

在 Linux 上这属于 **链路层/原始套接字** 操作，通常依赖：

- Scapy / **libpcap**（当前 Sidecar 用 `bmv2_try_acquire.py`），或  
- **DPDK**（论文里 C++ `lib` 的生产路径）

它们都 **直接操作网卡**，不是 `HttpClient.post()` 那种应用层调用。

### 2.3 「不方便又 root 又发包」是什么意思？

拆成两半理解。

**（1）「发包」往往需要更高权限**

向 `veth-inject` 注入原始帧时，进程通常需要：

- 以 **`sudo` / root** 运行，或  
- 具备 **`CAP_NET_RAW`** 等能力  

本仓库 VM 上的实际做法：

```bash
# Sidecar / Python 助手 — 有发包能力
sudo java -jar ... LockSidecarMain
sudo python3 scripts/bmv2_try_acquire.py try_acquire ...

# 业务示例 — 普通用户即可
bash scripts/vm-run-example.sh 1    # 内部是 mvn exec:java，无 sudo
```

若把发包写进 **同一个** 业务 JVM，要么整包 `sudo mvn exec:java`（业务进程权限过大），要么在 Java 里再 `ProcessBuilder("sudo", "python", ...)`——**能力上等价于现在的 Sidecar 后端**，只是代码写在业务进程里还是独立进程里的区别。

**（2）「不方便」还指工程与运维**

| 问题 | 说明 |
|------|------|
| 原生依赖 | Java 里用 Pcap4j 需系统 `libpcap.so`；`sudo java` 下曾出现 JNI/库路径问题（故 0.1 默认改 Scapy 子进程） |
| 与 DPDK 路线不符 | 完整 `lib` 绑核、大页、DPDK，不适合塞进普通 Spring Boot 式 JVM |
| 权限隔离 | 生产习惯：**业务进程权限小、可频繁重启**；**碰网卡/root 的组件单独部署** |
| 多实例 | 多个业务 JVM 可共用一个 Sidecar（:gRPC），不必每个都 root + 绑网卡 |

所以这句话的准确含义是：

> **不是 Java 语言不能发包，而是让「跑业务的那个 JVM」同时承担 root 和底层网卡注入，通常不合适；因此把发包放到 Sidecar（或以后的 native / `lib`）里。**

### 2.4 能不能不要 Sidecar，锁全在 Java 里？

分两种「全在 Java」：

| 你的目标 | 能否只靠 Java | 说明 |
|----------|---------------|------|
| 只演示 **发 ACQUIRE、等 GRANT**（0.1） | 技术上可以 | 例如 `sudo` 跑同一个 JVM + Pcap4j，或 Java 内调 `sudo python`；**不会自动拥有** `lib` 的队列与 agent |
| **完整 FissLock 锁管理** | 不能只写 Java API | 需 **JNI 链到 `lib`**，或在 Java 里重写 `lock.cc` 同级逻辑，工作量远大于 Sidecar |
| 最终生产形态 | Sidecar 可合并或保留 | 0.2：Sidecar 内 **JNI → `lib`**；也可业务 jar 直接加载 `.so`，少一个进程，但 native/权限问题仍在 |

和 **Redisson** 的类比：业务代码不自己拼 Redis 协议，而是连 **另一个专门干网络与协议的服务/进程**；这里 Sidecar 扮演「协议代理」，后端是 **交换机锁包** 而不是 Redis。

### 2.5 当前联调里两个 Java 进程各干什么

```text
BasicExample（普通用户）
  · 只调 FissLockClient → localhost:50051
  · 不打开 veth-inject，不 sudo

LockSidecarMain（sudo）
  · 收 gRPC TryAcquire / Release
  · 调 bmv2_try_acquire.py：sendp(ACQUIRE)、读 build/pcap 判 GRANT、sendp(FREE)
  · 仍不做 lib 的等待队列与 agent_daemon
```

**结论**：Sidecar = **带 root/发包能力的适配进程**；**不是**完整锁管理器。完整锁管理在 **`lib`**；锁决策快路径在 **交换机**。

---

## 3. 联调时后台在跑什么？

典型需要 **3 个角色**（2～3 个 SSH 终端）：

| # | 进程 | 启动命令 | 前台/后台 | 作用 |
|---|------|----------|-----------|------|
| ① | **simple_switch** | `RESTART=1 bash scripts/start_switch.sh` | **后台**（nohup） | 加载 `fisslock_bmv2.json`，执行 P4 锁逻辑，写 `build/pcap/` |
| ② | **Lock Sidecar** | `bash scripts/vm-run-sidecar.sh` | **前台**（占终端） | gRPC 服务；发 ACQUIRE、读 GRANT |
| ③ | **BasicExample** | `bash scripts/vm-run-example.sh 1` | 前台（跑完退出） | 演示 `tryLock` / `unlock` |

**注意**：只能有 **1 个** `simple_switch` 绑 `fisslock_bmv2.json`。多个实例会导致行为混乱（`vm-check.sh` 会警告）。

### 3.1 虚拟网卡

| 网卡 | 对接 |
|------|------|
| `veth-inject` ↔ `veth-switch` | 交换机 **port 0**；Sidecar / Scapy **从这里注入** |
| `veth-h1` ↔ `veth-host1` | port 1，常作 host_id=1 |
| `veth-h2` ↔ `veth-host2` | port 2，常作 host_id=2 |

### 3.2 重要目录

| 路径 | 作用 |
|------|------|
| `switch/p4_bmv2/build/pcap/` | 交换机抓包；Sidecar **从 `*_out.pcap` 读 GRANT** |
| `switch/p4_bmv2/build/switch.log` | 交换机日志 |
| `java/fisslock-java/target/*.jar` | Sidecar 可执行 JAR |

---

## 4. 一次 `tryLock` 谁做了什么？

1. **BasicExample**：`FissLockClient.connectLocal(1)` → `getLock("order:1001").tryLock()`
2. **gRPC**：`TryAcquireRequest` → Sidecar `:50051`
3. **Sidecar**：`order:1001` 映射为 **`lock_id=1`**（演示用，与 Python 状态机一致）
4. **Sidecar**：在 `veth-inject` 发 **ACQUIRE**（17 字节 UDP 锁包，对齐 `lib/post.h`）
5. **simple_switch**：P4 处理 → 更新 `lock_free` / agent 等 → 产生 **GRANT**
6. **Sidecar**：发现 `build/pcap` 增大，解析 `veth-switch_out.pcap` 等中的 **GRANT_W_AGENT**
7. **gRPC 返回** `granted=true` → Java 进入临界区 → `unlock` → Sidecar 发 **FREE**

**为何从 pcap 读 GRANT？**  
Python `test_paths.py` 已证明交换机正常；在线 `live sniff` 在部分环境收不到包，故 Sidecar 与测试脚本 **同一数据源**（`build/pcap`）。

---

## 5. 三条数据面路径（论文核心）

| 路径 | P4 在做什么 | Python 怎么测 | Java 阶段 0.1 |
|------|-------------|---------------|----------------|
| **状态机** | 空闲锁首次 ACQUIRE → GRANT_W_AGENT | `test_paths --only state` | `order:1001` → lock_id=1，独占 tryLock |
| **组播** | shared 二次 ACQUIRE → mgrp 299 两副本 | `--only mcast` | 未完整覆盖 |
| **counter** | TRANSFER 时 ncnt 与交换机计数一致 | `--only counter` | 未完整覆盖 |

BMv2 三条路径 **已全部 PASS**（Python）见 [BMV2_UBUNTU_VALIDATION_zh.md](./BMV2_UBUNTU_VALIDATION_zh.md)。

---

## 6. Python 测试 vs Java 联调

| | `test_paths.py` | Java + Sidecar |
|--|-----------------|----------------|
| **目的** | 验证 **交换机 P4** | 验证 **Java → Sidecar → 交换机** |
| **入口** | Scapy 直接发包 | gRPC |
| **权限** | 通常要 sudo | 业务无需 sudo；Sidecar 要 sudo |
| **是否算「业务接 FissLock」** | 否 | 是（阶段 0.1） |

两者可共用同一台 VM、同一 `simple_switch`，但 **不要**在 Sidecar 处理请求时重复灌组播 CLI。

---

## 7. 和「完整锁管理」差什么？

| 能力 | 交换机 P4（已验证） | C++ `lib/`（未跑） | Java 0.1 |
|------|-------------------|-------------------|----------|
| 快速 grant / agent 指定 | ✅ | ✅ | ✅（经 Sidecar） |
| 等待队列、agent_daemon | ❌（在主机） | ✅ | ❌ |
| lock_register / RPC | ❌ | ✅ | ❌（演示用 hash→lock_id） |
| Redisson 式租约/看门狗 | ❌ | ❌ | ❌（需 Java 自实现） |

演进路线见 [JAVA_INTEGRATION_zh.md](./JAVA_INTEGRATION_zh.md)（0.2 接 `lib`，1.0 接 Tofino）。

---

## 8. 标准联调顺序（ checklist ）

```bash
# === 终端 1：交换机 ===
cd ~/fisslock/switch/p4_bmv2
export P4C="$HOME/tutorials/p4c-stable/build/p4c"
export PATH="$HOME/tutorials/p4c-stable/build:/usr/local/bin:$PATH"
bash scripts/stop_switch.sh && bash scripts/stop_switch.sh
sudo rm -f build/pcap/*.pcap
RESTART=1 bash scripts/start_switch.sh
echo mc_dump | sudo simple_switch_CLI | grep -A3 'mgrp(299)'

# === 终端 2：Sidecar（保持运行）===
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-sidecar.sh
# 期望: grant-from-pcap=.../build/pcap

# === 终端 3：Java 示例 ===
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-example.sh 1
# 期望: held, critical section / released
```

编译 JAR（代码更新后）：

```bash
cd ~/fisslock/java/fisslock-java
mvn -q package -DskipTests
```

---

## 9. 常见问题速查

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `gRPC UNKNOWN` | Sidecar 内未捕获错误（如 pcap 读失败） | 看 **Sidecar 终端堆栈**；`sudo ldconfig`；重编 JAR |
| `tryLock` 卡很久 | 旧版无 gRPC 超时 | 更新代码、`mvn package` |
| `not granted` / timeout | 未收到 GRANT | 确认 1 个 switch；Python state 是否 PASS |
| `ss` 有 50051 但无 Acquire 日志 | 连错进程 / Sidecar 未起 | `sudo ss -tlnp \| grep 50051` |
| 组播 CLI `INVALID_L1_HANDLE` | `mc_node_associate` 用了 rid 而非 handle | 用仓库最新 `multicast.txt`；勿重复灌表 |
| `scp` 失败 `No such file` | 远程目录不存在 | `ssh host "mkdir -p ~/fisslock/java"` |
| 多个 simple_switch | 多次 start 未 stop | `stop_switch.sh` 两次 + `pgrep` 确认 |

---

## 10. 文档索引

| 文档 | 何时看 |
|------|--------|
| [OPERATIONS_MANUAL_zh.md](./OPERATIONS_MANUAL_zh.md) | **按步骤联调**（三终端、CRLF、成功输出） |
| **本文** | 搞清架构、进程、Sidecar 含义 |
| [BMV2_UBUNTU_VALIDATION_zh.md](./BMV2_UBUNTU_VALIDATION_zh.md) | P4 三条路径验证、组播/thrift/pcap 排错 |
| [JAVA_INTEGRATION_zh.md](./JAVA_INTEGRATION_zh.md) | Java 阶段规划、与 Redisson 差异 |
| [JAVA_VM_DEPLOY_zh.md](./JAVA_VM_DEPLOY_zh.md) | scp 上传、VM 三终端步骤 |
| [../switch/LEARNING_zh.md](../switch/LEARNING_zh.md) | P4 / 锁包 / 锁裂变概念 |
| [../java/fisslock-java/README.md](../java/fisslock-java/README.md) | Maven 构建与脚本说明 |

---

## 11. 复现成功标准（当前阶段）

**交换机（Python）**

```text
[状态机] PASS  [组播] PASS  [counter] PASS  全部通过。
```

**Java（阶段 0.1）**

```text
Sidecar: [backend] sent ACQUIRE ...  [backend] GRANT from pcap ...
Example:   held, critical section  →  released
```

达到以上即：**BMv2 数据面 + Java 经 Sidecar 接锁** 联调成功；不等于 OSDI 全文实验复现。
