# C++ `lib/` 接入 BMv2 + Java Sidecar（阶段 0.2）

在 **不安装 DPDK** 的 p4dev VM 上，将论文 **`lib/lock.cc`** 主机锁逻辑经 JNI 接到 Java Sidecar，数据面仍为 BMv2 + `veth-inject`。

---

## 1. 架构

```text
Java BasicExample
    → gRPC → Lock Sidecar
                → JNI → libfisslock_bmv2.so
                            ├── lib/lock.cc   （等待队列、GRANT 处理、lock_release）
                            ├── lib/post.c    （17 字节锁包）
                            └── lib/bmv2/bmv2_net.cc  （libpcap 注入 + 读 build/pcap）
                → veth-inject → simple_switch
```

| 组件 | 说明 |
|------|------|
| `lib/lock.cc` | 论文主机锁；BMv2 下另有 **`#ifdef FISSLOCK_BMV2`** 本地等待队列（同机二次 ACQUIRE 不走慢路径发包），见 §4.1 |
| `lib/bmv2/` | BMv2 专用 **网络替换层**（不用 `lib/net.cc` / DPDK） |
| `python` 后端 | 0.1 演示，只发包不等 `lib` 队列 |
| `lib` 后端 | 0.2，走 **`lock_acquire_async` + `lock_packet_dispatch`** |

---

## 2. 与完整论文栈仍差什么

| 能力 | `lib` 后端（BMv2） | 论文 + DPDK 八机 |
|------|-------------------|------------------|
| `lock_local_init` / 独占 tryLock | ✅ | ✅ |
| 同机双 task 独占互斥（`ContentionExample`） | ✅（`FISSLOCK_BMV2` 本地 wqueue，见 `lock.cc`） | ✅ |
| 收 GRANT 更新 agent / `task_granted` | ✅ | ✅ |
| `lock_release` / FREE | ✅ | ✅ |
| `lock_init` + 控制面 RPC | ❌（用 `lock_local_init`） | ✅ |
| DPDK 收发包 | ❌（pcap） | ✅ |
| `agent_daemon` 独立线程 | 未单独启动（由 GRANT/包驱动） | 完整实验配置 |
| 共享锁组播 / TRANSFER 全路径 | 未在 Java 演示覆盖 | ✅ |

---

## 3. 编译（VM）

依赖：`g++`、`libpcap-dev`、`openjdk-17-jdk`（JNI 头文件）。

```bash
cd ~/fisslock/java/fisslock-java
sed -i 's/\r$//' scripts/*.sh && chmod +x scripts/*.sh
bash scripts/vm-build-lib.sh
```

产物：`~/fisslock/lib/bmv2/libfisslock_bmv2.so`

---

## 4. 运行

与 [OPERATIONS_MANUAL_zh.md](./OPERATIONS_MANUAL_zh.md) 相同：先 **交换机（终端 A）**，再 **Sidecar（终端 B）**，再 **Example（终端 C）**。  
**命令含义、名词、三窗口说明**见操作手册 **[§0 零基础速览](./OPERATIONS_MANUAL_zh.md#0-零基础速览三个窗口每条命令在干什么)**。

```bash
# 终端 B — C++ lib 后端
export LD_LIBRARY_PATH="$HOME/fisslock/lib/bmv2:$LD_LIBRARY_PATH"
export FISSLOCK_BACKEND=lib
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-sidecar.sh
```

期望 Sidecar 日志含：

```text
[lib] fl_bmv2_init host=1 iface=veth-inject pcap=...
[backend] lib native host=1 ... (lock.cc)
```

```bash
# 终端 C — 单客户端
bash scripts/vm-run-example.sh 1
```

### 4.1 多客户端抢锁（双线程 / 同一 `lock_id`）

证明主机 **`lock.cc` 等待队列**：线程 A 持锁期间，线程 B 的 `tryLock` 应阻塞，A `unlock` 后 B 才 GRANT。  
**逐步说明与排错**见 [OPERATIONS_MANUAL_zh.md §10](./OPERATIONS_MANUAL_zh.md#10-独占互斥验收contentionexample)。

```bash
# 终端 C（Sidecar 须 FISSLOCK_BACKEND=lib，且已 vm-build-lib.sh）
cd ~/fisslock/java/fisslock-java
sed -i 's/\r$//' scripts/vm-run-contention.sh   # 从 Windows scp 后必做
chmod +x scripts/vm-run-contention.sh
bash scripts/vm-run-contention.sh 5

# 推荐（不易跑错主类）：
mvn -q -Pcontention exec:java -Dexec.args="5 500"
```

**已验收终端 C 输出（2026-05-31，p4dev VM）**：

```text
[A] HOLDING 5 s ...
[B] tryLock (while A should hold) ...
[A] released
[B] GRANTED after 4965 ms ...
PASS: B waited 4965 ms while A held (min 3700 ms)
```

**已验收 Sidecar 顺序**：`GRANT task=20` → A `release` → B `Acquire` → `GRANT task=21` → B `release`。

| 结果 | 含义 |
|------|------|
| 末尾 **`PASS:`** | ✅ 独占互斥验收通过 |
| B 立刻 GRANT（不足 500ms） | ❌ 未串行化；查是否多实例 switch、Sidecar 是否为 `lib` |
| 仍是 `order:1001` 输出 | ❌ 跑成了 `BasicExample`；用 `-Pcontention` |
| `Connection refused :50051` | ❌ 终端 B Sidecar 未起 |
| B 超时 | ❌ 先在同一配置下跑通 `vm-run-example.sh` |

锁名 `contention:1` 映射 **`lock_id=1`**（与 `order:1001` 相同，对齐 BMv2 状态机用例）。

回退到 Scapy 助手：

```bash
export FISSLOCK_BACKEND=python
bash scripts/vm-run-sidecar.sh
```

---

## 5. 源码位置

| 路径 | 作用 |
|------|------|
| `lib/bmv2/net.h` | BMv2 下替换 `net.h`（编译时 `-Ilib/bmv2` 优先） |
| `lib/bmv2/bmv2_net.cc` | pcap 注入 / 扫 pcap 调 `packet_dispatch` |
| `lib/bmv2/fisslock_host_api.cc` | `fl_bmv2_*` C API + 轮询线程 |
| `lib/bmv2/fisslock_jni.cpp` | JNI |
| `java/.../LibNativeLockBackend.java` | Sidecar 后端 |
| `java/.../FisslockNative.java` | `System.loadLibrary("fisslock_bmv2")` |

---

## 6. 故障排查

| 现象 | 处理 |
|------|------|
| `UnsatisfiedLinkError: fisslock_bmv2` | `export LD_LIBRARY_PATH=~/fisslock/lib/bmv2:$LD_LIBRARY_PATH` |
| `missing libfisslock_bmv2.so` | `bash scripts/vm-build-lib.sh` |
| 编译缺 `jni.h` | `export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64` |
| tryLock 超时 | 单实例 switch；`test_paths` PASS 但 lib 仍超时 → 重编 `vm-build-lib.sh`（`bmv2_net` 须算 IP/UDP 校验和） |
| 链接错误 `undefined reference to rte_*` | 勿把 `lib/net.cc` 编进 BMv2 目标，只用 `lib/bmv2/Makefile` |

---

## 7. 演进

- **0.2（本文）**：BMv2 + `lock.cc` + JNI  
- **0.3+**：真 DPDK `lib/net.cc` + 多机 `env_setup`（复现论文实验）  
- **1.0**：Tofino + `lock_init` RPC  
