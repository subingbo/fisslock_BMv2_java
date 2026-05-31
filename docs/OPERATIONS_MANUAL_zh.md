# FissLock 操作手册（BMv2 + Java Sidecar）

本文是 **p4dev 虚拟机** 上的标准操作流程：从代码同步、交换机启动，到 Python 验证、**Java 独占锁 tryLock**，以及 **C++ `lib` 后端 + 双线程抢锁验收**。  
架构说明见 [ARCHITECTURE_AND_RUNBOOK_zh.md](./ARCHITECTURE_AND_RUNBOOK_zh.md)；P4 三条路径细节见 [BMV2_UBUNTU_VALIDATION_zh.md](./BMV2_UBUNTU_VALIDATION_zh.md)。

**若对命令不熟**：请先读 **[§0 零基础速览](#0-零基础速览三个窗口每条命令在干什么)**，再按 §5 / §5B / §10 复制粘贴。

---

## 0. 零基础速览：三个窗口、每条命令在干什么

### 0.1 你要完成的事（一句话）

在虚拟机里同时跑 **模拟交换机**、**锁服务（Sidecar）**、**你的 Java 程序**；程序通过 **网络** 向交换机要锁，交换机把「同意」写进文件，Sidecar 读出来再告诉 Java。

### 0.2 三个终端（窗口）分别是谁

| 窗口 | 角色 | 类比 | 必须一直开着？ |
|------|------|------|----------------|
| **终端 A** | BMv2 交换机 `simple_switch` | 实验室里的「锁服务器硬件」 | 实验期间是 |
| **终端 B** | Java **Sidecar**（监听 `50051`） | 帮你发 UDP、读回执的「司机」 | 实验期间是 |
| **终端 C** | 你的业务程序 `BasicExample` / `ContentionExample` | 真正写业务逻辑的 Java | 跑完就结束 |

业务 Java **不直接**往网卡发包，而是 **打电话（gRPC）** 给 Sidecar；Sidecar 再发包、读 `build/pcap/` 里的 GRANT。

### 0.3 常见命令白话

| 你看到的命令 | 白话 |
|--------------|------|
| `cd ~/fisslock/...` | 进入某个文件夹；**每条命令前都要在正确目录**，否则会「找不到文件」 |
| `scp -r D:\fisslock\... user@IP:~/fisslock/` | 在 **Windows PowerShell** 里，把本机文件夹 **复制到虚拟机**（改 IP 和用户名） |
| `sed -i 's/\r$//' scripts/*.sh` | 把 Windows 换行符 `\r` 去掉，否则 bash 报 `$'\r': command not found` |
| `chmod +x scripts/*.sh` | 给脚本「可执行」权限 |
| `export FISSLOCK_BACKEND=lib` | 仅**当前终端**生效：告诉 Sidecar 用 C++ `lib` 而不是 Python |
| `export LD_LIBRARY_PATH=...` | 让系统能找到 `libfisslock_bmv2.so` |
| `bash scripts/vm-run-sidecar.sh` | 启动 Sidecar（脚本里通常会 `sudo`，因为要往 `veth-inject` 发包） |
| `mvn -q package -DskipTests` | 用 Maven **编译** Java 工程，生成 JAR |
| `mvn -q -Pcontention exec:java -Dexec.args="5 500"` | 编译并运行 **抢锁演示**；`5` = A 持锁秒数，`500` = B 最少应等待毫秒数 |
| `Ctrl+C` | 停掉当前前台程序（如 Sidecar） |
| `pgrep -af simple_switch` | 看有几个交换机在跑；**只能有 1 个** |

### 0.4 名词对照（不用背，查表即可）

| 名词 | 含义 |
|------|------|
| **Sidecar** | 旁路服务：gRPC 端口 `50051`，负责发包/收 GRANT，不是你的业务代码 |
| **gRPC** | Java 与 Sidecar 之间的 RPC；连不上多半是 Sidecar 没起 |
| **`order:1001` / `contention:1`** | 锁的**名字**（字符串）；Sidecar 会映射成数字 **`lock_id=1`** |
| **`tryLock` / `unlock`** | Java API：尝试拿独占锁 / 释放 |
| **`build/pcap/`** | 交换机把经过的包抓下来；Sidecar **从这里读 GRANT** |
| **`FISSLOCK_BACKEND=python`** | Sidecar 用 Python 脚本发包（阶段 0.1，易上手） |
| **`FISSLOCK_BACKEND=lib`** | Sidecar 用论文 C++ `lock.cc` + JNI（阶段 0.2，含抢锁队列） |
| **`vm-build-lib.sh`** | 在 VM 上编译 `libfisslock_bmv2.so`（用 `lib` 后端前必做） |

### 0.5 推荐第一次路线

1. 按 §3 从 Windows **scp** 到 VM，并做 **sed 去 CRLF**。  
2. 按 §5：**终端 A → B（`python` 后端）→ C**，跑通 `vm-run-example.sh`。  
3. 再按 §5B：编译 `.so`，Sidecar 改 **`FISSLOCK_BACKEND=lib`**，仍跑 `vm-run-example.sh`。  
4. 最后按 §10：**抢锁验收**（`ContentionExample`），看到 **`PASS:`** 即证明独占互斥。

---

## 1. 适用范围

| 包含 | 不包含 |
|------|--------|
| BMv2 `simple_switch` + veth | Tofino 真机、`switch/p4` + 控制面 |
| Python `test_paths.py` 三条数据面 | 论文八机 DPDK + `agent_daemon` 全栈 |
| Java **0.1**：Sidecar + `python` + `BasicExample` | 8 机压测、`baseline/` 对比实验 |
| Java **0.2**：`FISSLOCK_BACKEND=lib` + `ContentionExample` 抢锁 | 共享锁组播 / TRANSFER 全路径（见 [LIB_BMV2_INTEGRATION_zh.md](./LIB_BMV2_INTEGRATION_zh.md)） |

**成功标准**

| 阶段 | 终端 C 应看到 | Sidecar（终端 B）应看到 |
|------|----------------|-------------------------|
| 0.1 单客户端 | `held, critical section` / `released` | `[python]` 或 `[backend] GRANT` |
| 0.2 抢锁互斥 | 末尾 **`PASS: B waited ... ms`** | A 的 `GRANT` → `release` → 再 B 的 `GRANT`（见 §10） |

**为何业务 Java 不直接发包、而要 Sidecar？** 见 [ARCHITECTURE_AND_RUNBOOK_zh.md §2](./ARCHITECTURE_AND_RUNBOOK_zh.md#2-sidecar-是什么)（含「root + 发包」含义、与 `lib` 分工）。

---

## 2. 环境与路径

### 2.1 假设

- 虚拟机：Ubuntu（p4dev），用户示例 `subingbo@192.168.43.110`
- 仓库在 VM：`~/fisslock`
- P4 编译器：`~/tutorials/p4c-stable/build/p4c`
- Python（Scapy）：`~/tutorials/p4dev-python-venv/bin/python3`

### 2.2 关键目录

| 路径 | 作用 |
|------|------|
| `~/fisslock/switch/p4_bmv2/` | BMv2 交换机脚本、P4、`build/pcap/` |
| `~/fisslock/java/fisslock-java/` | Java 工程、Sidecar JAR、shell 脚本 |
| `~/fisslock/switch/p4_bmv2/build/pcap/` | 交换机抓包；Sidecar **从此读 GRANT** |
| `~/fisslock/java/fisslock-java/target/fisslock-java-0.1.0-SNAPSHOT.jar` | Sidecar 可执行 JAR |

### 2.3 虚拟网卡

| 网卡 | 用途 |
|------|------|
| `veth-inject` | **注入锁包**（Python / Sidecar 发包） |
| `veth-switch` | 交换机 port 0 |
| `veth-h1` / `veth-h2` | port 1 / 2（host_id 1 / 2） |

---

## 3. 从 Windows 同步代码

在 **PowerShell** 中（按你的 IP/用户名修改）：

```powershell
ssh subingbo@192.168.43.110 "mkdir -p ~/fisslock/java ~/fisslock/lib ~/fisslock/docs ~/fisslock/switch"
scp -r D:\fisslock\java\fisslock-java subingbo@192.168.43.110:~/fisslock/java/
scp -r D:\fisslock\lib subingbo@192.168.43.110:~/fisslock/
scp -r D:\fisslock\docs subingbo@192.168.43.110:~/fisslock/
scp -r D:\fisslock\switch\p4_bmv2 subingbo@192.168.43.110:~/fisslock/switch/
```

说明：`lib/` 只有在你用 **`FISSLOCK_BACKEND=lib`**（阶段 0.2）时才必须同步；只做 0.1 可先不传。

### 3.1 修正脚本换行（必做）

从 Windows `scp` 后，`.sh` 常为 **CRLF**，bash 会报：

- `set: -: invalid option`
- `$'\r': command not found`

在 VM 上执行（**不依赖任何脚本**）：

```bash
sed -i 's/\r$//' ~/fisslock/java/fisslock-java/scripts/*.sh
chmod +x ~/fisslock/java/fisslock-java/scripts/*.sh
echo OK
```

若 `switch/p4_bmv2/scripts/*.sh` 也报错，同样处理：

```bash
sed -i 's/\r$//' ~/fisslock/switch/p4_bmv2/scripts/*.sh
chmod +x ~/fisslock/switch/p4_bmv2/scripts/*.sh
```

---

## 4. 首次安装（仅一次）

### 4.1 系统依赖

```bash
# BMv2 CLI / 组播
sudo apt-get install -y python3-thrift

# Java Sidecar
sudo apt-get install -y openjdk-17-jdk maven libpcap-dev
```

### 4.2 编译 Java

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-setup.sh
```

### 4.3 环境变量（写入 `~/.bashrc` 可选）

```bash
export P4C="$HOME/tutorials/p4c-stable/build/p4c"
export PATH="$HOME/tutorials/p4c-stable/build:/usr/local/bin:$PATH"
```

---

## 5. 标准联调流程（三终端）

每次实验建议按 **A → B → C** 顺序；**全程保持仅 1 个** `simple_switch` 进程。

### 终端 A — 启动 BMv2 交换机

```bash
cd ~/fisslock/switch/p4_bmv2
export P4C="$HOME/tutorials/p4c-stable/build/p4c"
export PATH="$HOME/tutorials/p4c-stable/build:/usr/local/bin:$PATH"

bash scripts/stop_switch.sh
bash scripts/stop_switch.sh
sudo rm -f build/pcap/*.pcap
RESTART=1 bash scripts/start_switch.sh

# 可选：确认组播 299 已配置
echo mc_dump | sudo simple_switch_CLI | grep -A3 'mgrp(299)'
```

**注意**

- 只在 **stop 之后、start 之前** 删除 `build/pcap/*.pcap`；**start 之后不要删**，否则读不到 GRANT。
- 不要对 `multicast.txt` 重复手动灌表（会 `INVALID_L1_HANDLE`）。

### 终端 B — 启动 Java Sidecar（保持运行）

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-sidecar.sh
```

**正常启动日志示例**

```text
==> FissLock sidecar backend=python send=veth-inject pcap=.../build/pcap port=50051
[backend] python=.../p4dev-python-venv/bin/python3 script=.../bmv2_try_acquire.py ...
FissLock sidecar listening on 50051, backend=python ...
```

`SLF4J: StaticLoggerBinder` 可忽略。

代码有更新时，先编译再重启 Sidecar：

```bash
cd ~/fisslock/java/fisslock-java
mvn -q package -DskipTests
# Ctrl+C 停掉旧 Sidecar 后
bash scripts/vm-run-sidecar.sh
```

### 终端 C — 验证与 Java 示例

**步骤 1：Python 三条数据面（可选，建议首次做）**

```bash
cd ~/fisslock/switch/p4_bmv2
sudo ~/tutorials/p4dev-python-venv/bin/python3 test/test_paths.py \
  --iface veth-inject --only all --pcap-dir build/pcap
```

期望：**状态机 / 组播 / counter 全部 PASS**。

**步骤 2：Scapy 助手（不经过 Java）**

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-test-python-backend.sh
```

期望：

```json
{"granted": true, "with_agent": true, "lock_id": 1, "grant_type": 2}
```

**步骤 3：Java 业务示例**

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-example.sh 1
```

期望：

```text
tryLock order:1001 ... (gRPC -> sidecar -> ACQUIRE, 最多约 3s)
  held, critical section
  released
```

**步骤 4：看 Sidecar 终端（应有）**

```text
[sidecar] Acquire key=order:1001 lock_id=1 ...
[python] {"granted": true, ...}
[backend] GRANT lock_id=1 type=2 (python)
```

---

## 5B. C++ `lib` 后端联调（阶段 0.2）

在 §5 的 **终端 A 已启动交换机** 的前提下进行。

### 步骤 1：编译 native 库（每个 VM 至少一次；改 `lib/` 或 `lock.cc` 后重做）

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-build-lib.sh
```

成功时存在：`~/fisslock/lib/bmv2/libfisslock_bmv2.so`

### 步骤 2：终端 B 用 `lib` 启动 Sidecar

```bash
cd ~/fisslock/java/fisslock-java
export LD_LIBRARY_PATH="$HOME/fisslock/lib/bmv2:$LD_LIBRARY_PATH"
export FISSLOCK_BACKEND=lib
bash scripts/vm-run-sidecar.sh
```

**正常日志应含**（大意即可）：

```text
[lib] fl_bmv2_init host=1 iface=veth-inject pcap=...
[backend] lib native host=1 ... (lock.cc)
FissLock sidecar listening on 50051, backend=lib ...
```

### 步骤 3：终端 C 单客户端（与 0.1 相同脚本）

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-example.sh 1
```

仍应出现 `held, critical section` / `released`；Sidecar 里是 `[backend] GRANT (lib)` 而不是 `[python]`。

### 步骤 4：抢锁验收

见 **[§10 独占互斥验收](#10-独占互斥验收contentionexample)**。

更细的架构与 `FISSLOCK_BMV2` 补丁说明见 [LIB_BMV2_INTEGRATION_zh.md](./LIB_BMV2_INTEGRATION_zh.md)。

---

## 6. 一次 tryLock 发生了什么

```text
BasicExample (Java)
    │ gRPC TryAcquire("order:1001")
    ▼
Lock Sidecar (:50051)
    │ order:1001 → lock_id=1（演示映射）
    │ sudo python3 bmv2_try_acquire.py try_acquire
    ▼
veth-inject → simple_switch (P4)
    │ GRANT_W_AGENT 写入 build/pcap/*_out.pcap
    ▼
Sidecar 解析 pcap → gRPC granted=true
    ▼
Java 进入临界区 → unlock → Sidecar 发 FREE
```

演示锁名 `order:1001` 固定映射为 `lock_id=1`，与 Python 状态机用例一致。

---

## 7. 停止与清理

```bash
# 停 Sidecar：在终端 B 按 Ctrl+C

# 停交换机
cd ~/fisslock/switch/p4_bmv2
bash scripts/stop_switch.sh
bash scripts/stop_switch.sh

# 确认无残留
pgrep -af 'simple_switch.*fisslock_bmv2' || echo "no switch"
```

快速检查脚本：

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-check.sh
```

---

## 8. 环境变量（Sidecar）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FISSLOCK_BACKEND` | `python` | 推荐；`pcap` 为 Pcap4j（部分环境不稳定） |
| `FISSLOCK_PYTHON` | `~/tutorials/p4dev-python-venv/bin/python3` | Scapy 解释器 |
| `FISSLOCK_PCAP_DIR` | `~/fisslock/switch/p4_bmv2/build/pcap` | GRANT 来源 |
| `FISSLOCK_SEND_IFACE` | `veth-inject` | 发包网卡 |
| `FISSLOCK_GRPC_PORT` | `50051` | gRPC 端口 |
| `FISSLOCK_MACHINE_ID` | `1` | 与 P4 中 machine_id 一致 |

示例：改用 **C++ lib** 后端（阶段 0.2，需先 `bash scripts/vm-build-lib.sh`）

```bash
export LD_LIBRARY_PATH="$HOME/fisslock/lib/bmv2:$LD_LIBRARY_PATH"
export FISSLOCK_BACKEND=lib
bash scripts/vm-run-sidecar.sh
```

示例：改用 Pcap4j 后端

```bash
export FISSLOCK_BACKEND=pcap
bash scripts/vm-run-sidecar.sh
```

---

## 9. 故障排查

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `set: -: invalid option` / `$'\r'` | 脚本 CRLF | §3.1 `sed -i 's/\r$//' ...` |
| `interface not found` | veth 未创建 | `cd ~/fisslock/switch/p4_bmv2 && sudo bash scripts/setup_veth.sh` |
| `pcap dir missing` | 交换机未启动 | 终端 A 执行 `RESTART=1 start_switch.sh` |
| Python `FAIL` / 无 GRANT | 多实例 switch；pcap 被删 | `stop` 两次；**仅 stop 后** 清 pcap；只保留 1 个 switch |
| `vm-test-python-backend` 失败 | 同上 | 先 `test_paths --only state` |
| `tryLock` 超时 / `not granted` | Sidecar 未起；switch 未起 | 先 B 再 C；看 Sidecar 是否有 `[python]` |
| gRPC `UNKNOWN` | 旧 JAR；Python 路径错 | `mvn package`；重启 Sidecar；看堆栈 |
| 组播 CLI 报错 | 重复灌表；rid 当 handle | 用仓库 `multicast.txt`；依赖 start 时自动灌表 |
| `mvn: command not found` | 未装 JDK/Maven | `bash scripts/vm-setup.sh` |
| gRPC 连不上 | 端口未监听 | `ss -tlnp \| grep 50051`；先起 Sidecar |

**推荐诊断顺序**

1. `pgrep -af simple_switch` → 仅 1 条  
2. `test_paths.py --only state` → PASS  
3. `vm-test-python-backend.sh` → `granted: true`  
4. `vm-run-sidecar.sh` + `vm-run-example.sh`

---

## 10. 独占互斥验收（ContentionExample）

**要证明什么**：同一把锁（`contention:1` → `lock_id=1`）上，线程 **A 持锁时 B 不能立刻拿到**；A **`unlock` 之后**，B 才 GRANT。  
这是「多客户端抢锁 / 独占」在 **单机双线程** 下的最小演示。

### 10.1 前提

- 终端 A：交换机已 `start_switch`（仅 1 个 `simple_switch`）。  
- 终端 B：`FISSLOCK_BACKEND=lib` 且 Sidecar 在听 `50051`（见 §5B）。  
- 终端 C：在 `~/fisslock/java/fisslock-java` 目录。

### 10.2 推荐命令（二选一）

**方式 A — 脚本（参数 = A 持锁秒数）**

```bash
cd ~/fisslock/java/fisslock-java
sed -i 's/\r$//' scripts/vm-run-contention.sh
chmod +x scripts/vm-run-contention.sh
bash scripts/vm-run-contention.sh 5
```

**方式 B — Maven（更不容易跑错主类）**

```bash
cd ~/fisslock/java/fisslock-java
mvn -q -Pcontention exec:java -Dexec.args="5 500"
```

含义：`5` = A 故意持锁 5 秒；`500` = 若 B 等待不足 500ms 就 GRANT，程序会 **失败退出**（防止「假通过」）。

### 10.3 终端 C — 成功时长什么样（2026-05-31 VM 实测）

```text
[A] HOLDING 5 s ...
[B] tryLock (while A should hold) ...
[A] released
[B] GRANTED after 4965 ms ...
PASS: B waited 4965 ms while A held (min 3700 ms)
```

看到 **`PASS:`** 即验收通过。若出现 **`FAIL:`** 或 B 只等了几十毫秒就 GRANT，说明未串行化，按 §9 查多 switch / Sidecar 后端是否为 `lib`。

### 10.4 终端 B — Sidecar 日志顺序（应对照）

正确顺序大致为：

```text
[sidecar] Acquire ... task=20 ...   # A
[backend] GRANT (lib) ... task=20
[sidecar] release ... task=20        # A unlock
[sidecar] Acquire ... task=21 ...   # B（在 A release 之后才真正授权）
[backend] GRANT (lib) ... task=21
[sidecar] release ... task=21
```

若 B 的 `GRANT` 出现在 A 的 `release` **之前**，说明互斥未生效，不要当作通过。

### 10.5 常见误解

| 误解 | 说明 |
|------|------|
| 「改 `lock.cc` 是不是论文没有独占？」 | 论文有独占；BMv2 演示栈里同机第二次 ACQUIRE 会再走慢路径发包，需 **`FISSLOCK_BMV2`** 下本地等待队列配合（仅 BMv2 编译）。 |
| 「`Connection refused :50051`」 | 终端 B Sidecar 没起，或起在别的机器/端口。 |
| 输出仍是 `order:1001` | 跑成了 `BasicExample`；用 **`-Pcontention`** 或 `vm-run-contention.sh`。 |

---

## 11. 日常复现清单（简版）

**0.1 — Python 后端**

```bash
# VM：换行（scp 后）
sed -i 's/\r$//' ~/fisslock/java/fisslock-java/scripts/*.sh && chmod +x ~/fisslock/java/fisslock-java/scripts/*.sh

# A：交换机
cd ~/fisslock/switch/p4_bmv2 && export P4C=~/tutorials/p4c-stable/build/p4c PATH="$HOME/tutorials/p4c-stable/build:/usr/local/bin:$PATH"
bash scripts/stop_switch.sh; bash scripts/stop_switch.sh; sudo rm -f build/pcap/*.pcap; RESTART=1 bash scripts/start_switch.sh

# B：Sidecar（默认 python）
cd ~/fisslock/java/fisslock-java && bash scripts/vm-run-sidecar.sh

# C：Java
cd ~/fisslock/java/fisslock-java && bash scripts/vm-run-example.sh 1
```

**0.2 — lib 后端 + 抢锁（在 A 已起的前提下）**

```bash
cd ~/fisslock/java/fisslock-java && bash scripts/vm-build-lib.sh
export LD_LIBRARY_PATH="$HOME/fisslock/lib/bmv2:$LD_LIBRARY_PATH" FISSLOCK_BACKEND=lib
bash scripts/vm-run-sidecar.sh
# 另开终端 C：
mvn -q -Pcontention exec:java -Dexec.args="5 500"
```

---

## 12. 脚本索引

| 脚本 | 位置 | 作用 |
|------|------|------|
| `vm-setup.sh` | `java/fisslock-java/scripts/` | 装依赖 + `mvn package` |
| `vm-run-sidecar.sh` | 同上 | 启动 gRPC Sidecar（sudo） |
| `vm-run-example.sh` | 同上 | 运行 `BasicExample` |
| `vm-build-lib.sh` | 同上 | 编译 `libfisslock_bmv2.so` |
| `vm-run-contention.sh` | 同上 | 运行抢锁演示（参数：持锁秒数） |
| `vm-test-python-backend.sh` | 同上 | 单独测 Scapy 助手 |
| `vm-check.sh` | 同上 | switch / gRPC / veth 快检 |
| `bmv2_try_acquire.py` | 同上 | Sidecar 调用的发包/读 pcap |
| `start_switch.sh` / `stop_switch.sh` | `switch/p4_bmv2/scripts/` | 启停 BMv2 |
| `test_paths.py` | `switch/p4_bmv2/test/` | 三条数据面自动测试 |

---

## 13. 与其它文档的关系

| 文档 | 何时阅读 |
|------|----------|
| **本文** | 按步骤操作、复现实验 |
| [ARCHITECTURE_AND_RUNBOOK_zh.md](./ARCHITECTURE_AND_RUNBOOK_zh.md) | 理解 Sidecar / lib / 交换机分工 |
| [BMV2_UBUNTU_VALIDATION_zh.md](./BMV2_UBUNTU_VALIDATION_zh.md) | P4 三条路径、组播/thrift 排错史 |
| [JAVA_INTEGRATION_zh.md](./JAVA_INTEGRATION_zh.md) | Java 阶段 0.1→1.0 规划 |
| [JAVA_VM_DEPLOY_zh.md](./JAVA_VM_DEPLOY_zh.md) | 部署要点（与本文 §3–5 重叠，可二选一） |
| [LIB_BMV2_INTEGRATION_zh.md](./LIB_BMV2_INTEGRATION_zh.md) | C++ `lib` + JNI、`FISSLOCK_BMV2` |
| [../switch/LEARNING_zh.md](../switch/LEARNING_zh.md) | P4 / 锁包 / 锁裂变概念 |

---

## 14. 已验证输出（参考）

以下为 VM 实测通过时的片段，便于对照。

**Python 助手**

```text
==> try_acquire lock_id=1 (order:1001 mapping)
{"granted": true, "with_agent": true, "lock_id": 1, "grant_type": 2}
```

**Java 示例**

```text
tryLock order:1001 ... (gRPC -> sidecar -> ACQUIRE, 最多约 3s)
  held, critical section
  released
```

至此 **阶段 0.1（Java 能发请求、能拿独占锁）** 联调完成。

**抢锁互斥（0.2，`FISSLOCK_BACKEND=lib`）**

```text
[A] HOLDING 5 s ...
[B] tryLock (while A should hold) ...
[A] released
[B] GRANTED after 4965 ms ...
PASS: B waited 4965 ms while A held (min 3700 ms)
```

至此 **阶段 0.2（`lock.cc` 等待队列 + 双线程独占互斥）** 在 BMv2 演示栈验收完成。
