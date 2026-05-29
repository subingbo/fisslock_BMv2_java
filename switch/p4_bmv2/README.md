# FissLock BMv2 功能验证

在**没有 Tofino** 时，用 BMv2 验证论文中的三条核心数据面路径：

1. **锁裂变状态机**：`lock_free` / `lock_rw` 寄存器 + agent 转移（`lock_op_table`）
2. **Counter 一致性**：`notification_cnt` 与包内 `ncnt` 比较（`counter_table`）
3. **组播授权**：`mcast_to_agent` → egress `egress_rid` 1/2 分别改写成 ACQUIRE(granted) 与 GRANT_WO_AGENT

与 Tofino 版的差异（刻意缩小范围）：

| 项目 | Tofino (`switch/p4/`) | BMv2 (`switch/p4_bmv2/`) |
|------|------------------------|---------------------------|
| 架构 | TNA + RegisterAction | v1model + `register.read/write` |
| 锁数量 | 3×2^19 slices | 单 slice 1024（`id` 高 22 位须为 0） |
| 双 mcast 组 | `mcast_grp_a` + `mcast_grp_b` | 单组 `299`，用 `egress_rid` 区分 |
| 控制面 | BFRT | `simple_switch_CLI` 组播配置 |

## 拓扑

```
port 0 (veth-switch)  ← 交换机侧；测试脚本用对端 **veth-inject**
port 1 (veth-h1)      ← host_id=1，常作 agent
port 2 (veth-h2)      ← host_id=2，常作 client
```

## 快速开始（Ubuntu 服务器）

完整步骤见 **[DEPLOY_UBUNTU.md](DEPLOY_UBUNTU.md)**。

```bash
cd switch/p4_bmv2
chmod +x scripts/*.sh run_bmv2.sh test/test_paths.py
sudo ./scripts/ubuntu-install-deps.sh   # 首次
./scripts/start_switch.sh               # 后台启动交换机
sudo python3 test/test_paths.py --iface veth-inject --pcap-dir build/pcap
```

## 预期结果

### 1. 状态机（`--only state`）

- 输入：`ACQUIRE` + excl，`lock_id=1`，`machine_id=1`
- 输出（port 1 pcap）：`type=2`（`GRANT_W_AGENT`），`udp.dport=20002`

### 2. 组播（`--only mcast`）

- 第一次 `ACQUIRE shared` from host 1 → 单播 grant
- 第二次 `ACQUIRE shared` from host 2（锁已为 shared）→ **组播 299**
- port 1：`type=1`（`ACQUIRE`），`granted=1`，`dport=20001`
- port 2：`type=3`（`GRANT_WO_AGENT`），`dport=20002`

### 3. Counter（`--only counter`）

- 第一次 `ACQUIRE shared` 使 switch 上 `ncnt=1`
- `TRANSFER` 且 `ncnt=0`：不匹配 → `agent_changed=0`，**不**执行 `transfer_agent`
- `TRANSFER` 且 `ncnt=1`：匹配 → 执行 `transfer_agent`，`type=GRANT_W_AGENT`

## 与主机栈对接

正式跑 `microbench` 时，UDP payload 格式见 `lib/post.h`（17 字节头），与本目录 `test_paths.py` 一致。DPDK 需把网卡接到 BMv2 port（veth 或 tap）。

## 文件

- `fisslock_bmv2.p4` — 合并后的数据面
- `setup/multicast.txt` — 组播组 1、2、299
- `test/test_paths.py` — Scapy 三条路径测试
- `run_bmv2.sh` — 编译 + 启动脚本
