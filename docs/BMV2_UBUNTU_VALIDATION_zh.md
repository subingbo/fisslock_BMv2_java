# FissLock BMv2 验证记录（Ubuntu / p4dev VM）

> 架构与 Sidecar / 进程说明见 **[ARCHITECTURE_AND_RUNBOOK_zh.md](./ARCHITECTURE_AND_RUNBOOK_zh.md)**。

本文记录在无 **Tofino** 环境下，用 **BMv2** 在 Ubuntu 上跑通 FissLock 三条数据面路径的过程：**锁裂变状态机**、**共享锁组播授权**、**counter 一致性**。  
目标不是论文完整实验（8 机 + DPDK + 性能），而是 `switch/p4_bmv2/` 的功能验证。

相关代码与脚本：`switch/p4_bmv2/`；概念导读见 `switch/LEARNING_zh.md`。

---

## 1. 背景：为什么要用 BMv2

| 问题 | 做法 |
|------|------|
| 没有 Tofino 硬件 | 用 `simple_switch` 加载 `fisslock_bmv2.p4` 编译出的 JSON，在软件里仿真 P4 逻辑 |
| 需要验证论文核心数据面 | 用 Scapy 脚本 `test/test_paths.py` 发 17 字节锁包，读 `build/pcap/` 自动判定三条路径 |
| 开发与调试在 Windows，运行在 Linux VM | 代码放在 `~/fisslock`，通过 SSH / `scp` 同步；测试在 VM **本机** veth 上完成（不经过 SSH 网卡 IP） |

BMv2 与 Tofino 版在寄存器、组播 API 上有差异，逻辑对齐说明见 `switch/LEARNING_zh.md` 第 6 节。

---

## 2. 做了什么（摘要）

### 2.1 P4 与测试

- 维护/修复 `switch/p4_bmv2/fisslock_bmv2.p4`：V1Switch 命名、checksum、BMv2 不支持的 `RegisterAction` 条件写、锁头 17 字节与 `lib/post.h` 对齐等。
- `test/test_paths.py`：向 `veth-inject` 发包，解析 pcap，对 **state / mcast / counter** 做自动 PASS/FAIL 判定。

### 2.2 脚本与组播

- `scripts/start_switch.sh`：编译 P4 → 建 veth → 后台 `simple_switch` → **启动时灌组播**（过滤 `#` 注释行）。
- `scripts/stop_switch.sh`：按 JSON 路径 `pkill` 交换机。
- `scripts/apply_multicast.sh`：仅在 `mc_dump` 里没有 `mgrp(299)` 时手动灌表；已存在则跳过（避免重复灌表 ERROR）。
- `setup/multicast.txt`：只保留组播组 **299**，两节点 rid 1→port1、rid 2→port2；`mc_node_associate` 使用 **node handle 0/1**，不是 rid。
- `setup/multicast.txt.README`：组播语义说明（CLI 文件里不写 `#` 注释）。

### 2.3 环境与排错过程中修过的问题

- Windows 脚本 **CRLF** → Linux 上 `bash` 报错，需 `sed -i 's/\r$//'`。
- `p4c` 不在 PATH → `export P4C=~/tutorials/p4c-stable/build/p4c`。
- `simple_switch_CLI` 缺 **thrift** → Ubuntu 24.04 用 **`sudo apt-get install python3-thrift`**（不要用 `sudo pip3`，会 PEP 668 报错）。
- 组播 CLI：`#` 行报 Unknown syntax；`mc_node_associate` 第二参数必须是 **handle**；**start 后又手动灌组播** 会 ERROR（handle 已占用）。
- **启动后 `rm build/pcap/*.pcap`** 会导致测试无包 → 须在 **stop 之后、start 之前** 清 pcap，或 `RESTART=1 start`。

### 2.4 验证结果（2025 年 VM 实测）

在 `mc_dump` 显示 `mgrp(299)` 且两条 L1 节点正确后，执行：

```bash
sudo .../p4dev-python-venv/bin/python3 test/test_paths.py \
  --iface veth-inject --only all --pcap-dir build/pcap
```

输出：**状态机 PASS、组播 PASS、counter PASS、全部通过。**

---

## 3. 为什么这样做

### 3.1 为什么用 veth 而不是真实网卡

`simple_switch` 用 `-i 0@veth-switch -i 1@veth-h1 -i 2@veth-h2` 绑定虚拟口；测试脚本向 **对端** `veth-inject` 注入流量，等价于 port0 进交换机。无需多机，单机即可复现三条路径。

| 端口 | 交换机侧 | 测试/抓包侧 |
|------|----------|-------------|
| 0 | `veth-switch` | `veth-inject`（**发包用此 iface**） |
| 1 | `veth-h1` | `veth-host1` |
| 2 | `veth-h2` | `veth-host2` |

### 3.2 为什么组播只用 mgrp 299

P4 常量 `MCAST_SHARED_GRANT = 299`：共享锁**第二次 ACQUIRE** 走 `op_mcast_to_agent`，ingress 设 `mcast_grp = 299`。  
Egress 按 `standard_metadata.egress_rid` 区分副本：

- **rid=1** → port1：改成 `ACQUIRE` + `granted`（通知 agent）
- **rid=2** → port2：改成 `GRANT_WO_AGENT`（client 授权）

因此 `multicast.txt` 只需 5 行 CLI，不必再建组 1、2。

### 3.3 为什么 `mc_node_associate 299 0` 而不是 `299 1`

BMv2 中：

- `mc_node_create <rid> <port>` 的 **rid** 会出现在 egress 的 `egress_rid`。
- 命令返回的 **handle**（0、1、2…）才用于 `mc_node_associate <mgrp> <handle>`。

第一个节点 handle 恒为 **0**（全新交换机），第二个为 **1**。把 rid 当成 handle 会 `INVALID_L1_HANDLE` 或 `ERROR`。

### 3.4 为什么组播只在 start 时灌一次

`start_switch.sh` 启动后已向 PRE 写入 `mgrp(299)`。再执行一遍 `simple_switch_CLI` 会新建 handle 2、3，却仍 associate 0、1 → **ERROR**。  
正确做法：启动后 `echo mc_dump | sudo simple_switch_CLI | grep mgrp(299)` 确认即可。

### 3.5 为什么测试用 p4dev venv 的 Python + sudo

- **Scapy** 装在 `~/tutorials/p4dev-python-venv` 里，系统 `python3` 往往没有。
- 发/raw 包通常需要 **sudo**。
- `simple_switch_CLI` 走**系统 Python**，与 venv 无关；thrift 用 **apt 的 python3-thrift** 装到系统环境。

### 3.6 为什么 grant 常在 `veth-switch_out.pcap`

BMv2 上 agent 转发常把 grant 从 **port0** 送回 inject 侧；`test_paths.py` 的自动判定会在**全部 pcap** 里找 `GRANT_W_AGENT`，不限于 `h1_out`。组播则重点看 `veth-h1_out` / `veth-h2_out`。

---

## 4. 环境与路径（示例）

| 项 | 示例值 |
|----|--------|
| 仓库 | `~/fisslock` |
| BMv2 目录 | `~/fisslock/switch/p4_bmv2` |
| p4c | `~/tutorials/p4c-stable/build/p4c` |
| Python（测试） | `~/tutorials/p4dev-python-venv/bin/python3` |
| simple_switch / CLI | `/usr/local/bin` |

每次新开 shell 建议：

```bash
export P4C="$HOME/tutorials/p4c-stable/build/p4c"
export PATH="$HOME/tutorials/p4c-stable/build:/usr/local/bin:$PATH"
cd ~/fisslock/switch/p4_bmv2
```

---

## 5. 一次性完整验证流程（推荐命令）

在 **VM 本机**执行（不要 SSH 到别的机器再跑同一套，除非代码已同步到那台机）。

```bash
cd ~/fisslock/switch/p4_bmv2
export P4C="$HOME/tutorials/p4c-stable/build/p4c"
export PATH="$HOME/tutorials/p4c-stable/build:/usr/local/bin:$PATH"

# 1) 停交换机，清 pcap（仅 stop 之后删）
bash scripts/stop_switch.sh
sudo rm -f build/pcap/*.pcap

# 2) 编译 + veth + 后台 switch + 灌组播
RESTART=1 bash scripts/start_switch.sh

# 3) 确认组播（有输出即可，勿再灌）
echo mc_dump | sudo simple_switch_CLI | grep -A5 'mgrp(299)'

# 4) 三条路径自动测试（启动后不要再 rm pcap）
sudo "$HOME/tutorials/p4dev-python-venv/bin/python3" test/test_paths.py \
  --iface veth-inject --only all --pcap-dir build/pcap
```

期望 `mc_dump`：

```
mgrp(299)
  -> (L1h=0, rid=1) -> (ports=[1], lags=[])
  -> (L1h=1, rid=2) -> (ports=[2], lags=[])
```

期望测试末尾：`[状态机] PASS`、`[组播] PASS`、`[counter] PASS`、`全部通过。`

---

## 6. 常用命令速查

### 6.1 交换机生命周期

```bash
cd ~/fisslock/switch/p4_bmv2

# 启动（已运行且未删 pcap 时不会重启）
bash scripts/start_switch.sh

# 强制重启（改过 pcap 目录或需干净 PRE）
bash scripts/stop_switch.sh
sudo rm -f build/pcap/*.pcap
RESTART=1 bash scripts/start_switch.sh

# 停止
bash scripts/stop_switch.sh

# 查看是否在跑
pgrep -af 'simple_switch.*fisslock_bmv2'
cat build/simple_switch.pid
```

### 6.2 编译与组播

```bash
# 仅编译 P4
"$P4C" --target bmv2 --arch v1model -o build fisslock_bmv2.p4

# 查看组播表
echo mc_dump | sudo simple_switch_CLI

# 仅当 mc_dump 无 mgrp(299) 时
bash scripts/apply_multicast.sh

# 查看启动/组播日志
tail -50 build/switch.log
grep -E 'mgrp|Associating|ERROR' build/switch.log
```

### 6.3 测试

```bash
PY="$HOME/tutorials/p4dev-python-venv/bin/python3"

# 全部路径 + pcap 判定
sudo "$PY" test/test_paths.py --iface veth-inject --only all --pcap-dir build/pcap

# 分项
sudo "$PY" test/test_paths.py --iface veth-inject --only state  --pcap-dir build/pcap
sudo "$PY" test/test_paths.py --iface veth-inject --only mcast  --pcap-dir build/pcap
sudo "$PY" test/test_paths.py --iface veth-inject --only counter --pcap-dir build/pcap

# 只发包、不看 pcap 判定
sudo "$PY" test/test_paths.py --iface veth-inject --only state
```

### 6.4 查看 pcap

```bash
# 脚本内建的锁包摘要（测试时自动打印）
# 手动用 tcpdump
sudo tcpdump -r build/pcap/veth-h1_out.pcap -nn 'udp port 20001 or udp port 20002'
sudo tcpdump -r build/pcap/veth-switch_out.pcap -nn 'udp port 20002'
ls -la build/pcap/
```

### 6.5 脚本与换行（从 Windows 同步后）

```bash
sed -i 's/\r$//' scripts/*.sh run_bmv2.sh 2>/dev/null
chmod +x scripts/*.sh
```

### 6.6 依赖

```bash
# BMv2 CLI 所需（Ubuntu 24.04）
sudo apt-get install -y python3-thrift

# 不要用（会 externally-managed-environment）
# sudo pip3 install thrift

# 确认工具
which p4c simple_switch simple_switch_CLI
"$HOME/tutorials/p4dev-python-venv/bin/python3" -c "import scapy; print('scapy OK')"
```

### 6.7 从 Windows 同步代码到 VM

在 **PowerShell**（路径按本机修改）：

```powershell
scp -r D:\fisslock\switch\p4_bmv2\setup\multicast.txt `
    D:\fisslock\switch\p4_bmv2\scripts\ `
    subingbo@192.168.43.110:~/fisslock/switch/p4_bmv2/
```

同步后务必在 VM 上 **stop → rm pcap → RESTART=1 start**，避免旧组播状态与旧脚本混用。

---

## 7. 三条路径测什么

| 路径 | 测试行为 | 期望（pcap） |
|------|----------|----------------|
| **状态机** | 对空闲锁 `ACQUIRE` exclusive | 出现 `GRANT_W_AGENT`(type=2)，`dport=20002`，如 lock=1 |
| **组播** | 同一 shared 锁先 host1 再 host2 两次 `ACQUIRE` | `h1_out`: `ACQUIRE`+granted；`h2_out`: `GRANT_WO_AGENT` lock=10 |
| **counter** | lock=20：先 `TRANSFER` ncnt=0（stale），再 ncnt=1 | 第二次 `TRANSFER` 后出现 lock=20 的 `GRANT_W_AGENT` |

锁包格式与类型定义见 `lib/post.h`、`switch/LEARNING_zh.md` §2。

---

## 8. 常见问题

| 现象 | 原因 | 处理 |
|------|------|------|
| `No module named 'thrift'` | 系统 Python 缺 thrift | `sudo apt-get install -y python3-thrift` |
| `externally-managed-environment` | Ubuntu 24 禁止 sudo pip | 用 apt 装 `python3-thrift` |
| `Unknown syntax: # ...` | CLI 不支持 `#` 注释 | `multicast.txt` 只保留命令行；说明见 `setup/multicast.txt.README` |
| `INVALID_L1_HANDLE` / associate ERROR | associate 用了 rid 而非 handle；或重复灌表 | 用 `299 0` / `299 1`；只灌一次；`RESTART=1 start` |
| `[warn] no pcap` | 启动后删了 pcap，或 switch 未跑 | stop → rm pcap → RESTART=1 start → 再测 |
| 组播 FAIL | mgrp 299 未配置 | 查 `mc_dump`；修 `multicast.txt` 后重启 switch |
| `host_fwd is not used` 编译警告 | BMv2 用 `egress_spec` 直接转发 | 可忽略或日后删未用表 |

---

## 9. 目录与进一步阅读

```
switch/p4_bmv2/
├── fisslock_bmv2.p4       # BMv2 P4 程序
├── setup/multicast.txt    # 组播 CLI（5 行，无注释）
├── setup/multicast.txt.README
├── scripts/
│   ├── start_switch.sh    # 推荐：后台启动 + 灌组播
│   ├── stop_switch.sh
│   └── apply_multicast.sh # 仅缺失 mgrp(299) 时用
├── test/test_paths.py     # Scapy 三路径测试
└── build/
    ├── pcap/              # 各 veth 的 in/out pcap
    └── switch.log
```

- 部署细节：`switch/p4_bmv2/DEPLOY_UBUNTU.md`
- P4 概念与 Tofino 对比：`switch/LEARNING_zh.md`

---

## 10. 与论文实验的边界

本次 BMv2 验证证明：**数据面 P4 逻辑**在仿真环境下对三条核心路径行为正确。  
未包含：多机 RDMA、DPDK 客户端、Tofino 线速、大规模性能数据。若要做完整论文复现，需按仓库根 `README.md` 准备 Tofino 与 8 机环境。
