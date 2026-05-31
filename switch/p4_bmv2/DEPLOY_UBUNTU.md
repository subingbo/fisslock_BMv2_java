# 在 Ubuntu 服务器上运行 FissLock BMv2

适用于 **无 Tofino**、用 BMv2 验证锁裂变 / counter / 组播路径。  
推荐系统：**Ubuntu 22.04 / 24.04**，root 或 sudo 权限。

---

## 一、把代码弄到服务器

实验机示例：**192.168.43.110**（在你本机执行 SSH，在服务器上执行后续命令）。

```bash
# 在你自己的电脑上登录服务器
ssh subingbo@192.168.43.110

# 在服务器上
cd ~/fisslock   # 即 /home/subingbo/fisslock
ls switch/p4_bmv2/fisslock_bmv2.p4

# 可选：记录服务器地址
cd switch/p4_bmv2
cp scripts/env.server.example scripts/env.server
# 编辑 FISSLOCK_ROOT 为实际路径
source scripts/env.server
```

> **说明**：BMv2 测试走本机 **veth**，不经过 `192.168.43.110` 这块网卡 IP。  
> 该 IP 仅用于 SSH 登录；锁包在服务器内部的虚拟网口之间转发。

---

## 二、安装依赖

### 方式 A：自动脚本（从源码编译 p4c + BMv2，较慢但可靠）

```bash
cd /opt/fisslock/switch/p4_bmv2
chmod +x scripts/*.sh run_bmv2.sh test/test_paths.py
sudo ./scripts/ubuntu-install-deps.sh
```

编译完成后确认：

```bash
export PATH=/usr/local/bin:$PATH
p4c --version
which simple_switch simple_switch_CLI
python3 -c "import scapy"
```

### 方式 B：已有 p4c / behavioral-model

若学校/实验室镜像已装好，只需：

```bash
sudo apt-get update
sudo apt-get install -y python3-pip iproute2
pip3 install scapy
```

---

## 三、启动交换机（推荐：后台一键）

```bash
cd /opt/fisslock/switch/p4_bmv2
export PATH=/usr/local/bin:$PATH   # 若 p4c 装在此目录

./scripts/start_switch.sh
```

脚本会：

1. `p4c` 编译 `fisslock_bmv2.p4`
2. 创建 veth：`veth-inject`↔`veth-switch`（port0）、`veth-host1`↔`veth-h1`（port1）、`veth-host2`↔`veth-h2`（port2）
3. 后台运行 `simple_switch`
4. 执行 `setup/multicast.txt` 配置组播

停止：

```bash
./scripts/stop_switch.sh
```

---

## 四、跑测试（Python 客户端）

```bash
cd /opt/fisslock/switch/p4_bmv2

# 发包网卡：veth-inject（对接 switch port 0）
sudo python3 test/test_paths.py --iface veth-inject --pcap-dir build/pcap

# 分项测试
sudo python3 test/test_paths.py --iface veth-inject --only state  --pcap-dir build/pcap
sudo python3 test/test_paths.py --iface veth-inject --only mcast  --pcap-dir build/pcap
sudo python3 test/test_paths.py --iface veth-inject --only counter --pcap-dir build/pcap
```

查看 pcap（需安装 `tcpdump` 或 `tshark`）：

```bash
tcpdump -r build/pcap/1.pcap -nn -X
tcpdump -r build/pcap/2.pcap -nn -X
```

---

## 五、三终端手动方式（调试用）

**终端 1 — 交换机**

```bash
cd switch/p4_bmv2
sudo ./scripts/setup_veth.sh
export PATH=/usr/local/bin:$PATH
./run_bmv2.sh    # 前台占用，Ctrl-C 停止
```

**终端 2 — 组播配置**（`start_switch.sh` 已做可跳过）

```bash
simple_switch_CLI < /opt/fisslock/switch/p4_bmv2/setup/multicast.txt
```

**终端 3 — 测试**

```bash
sudo python3 test/test_paths.py --iface veth-inject --pcap-dir build/pcap
```

---

## 六、远程服务器注意点

| 问题 | 处理 |
|------|------|
| SSH 断开后进程退出 | 用 `./scripts/start_switch.sh`（nohup），或 `tmux`/`screen` |
| 防火墙 | 本方案走 veth，**不需**开放公网 UDP 端口 |
| 无图形界面 | 仅命令行即可 |
| `simple_switch` 找不到 | `export PATH=/usr/local/bin:$PATH` 并 `ldconfig` |

持久化（可选）——用 systemd 管理，单元示例：

```ini
# /etc/systemd/system/fisslock-bmv2.service
[Unit]
Description=FissLock BMv2 simple_switch
After=network.target

[Service]
Type=forking
WorkingDirectory=/opt/fisslock/switch/p4_bmv2
ExecStart=/opt/fisslock/switch/p4_bmv2/scripts/start_switch.sh
ExecStop=/opt/fisslock/switch/p4_bmv2/scripts/stop_switch.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fisslock-bmv2
```

---

## 七、常见问题

**`: command not found` 或 `cannot execute: required file not found`**

脚本在 Windows 上编辑后带 **CRLF** 换行。在服务器执行：

```bash
cd ~/fisslock/switch/p4_bmv2
bash scripts/fix_crlf.sh
# 或
sudo apt-get install -y dos2unix
find . -name '*.sh' -exec dos2unix {} \;
sed -i 's/\r$//' scripts/env.server 2>/dev/null || true
```

之后用 **`bash scripts/...`** 启动，不要依赖 `./xxx.sh`：

```bash
bash scripts/start_switch.sh
```

**`p4c: command not found`（已在 p4dev-python-venv 里）**  

`p4dev-python-venv` 通常**只有 Python**，不含 `p4c`。先找并加载 P4 环境：

```bash
find $HOME /usr /opt -name 'p4setup.sh' -o -name 'p4setup.bash' 2>/dev/null | head -5
find $HOME /usr/local -name 'p4c' -type f 2>/dev/null | head -5

# 常见（路径按 find 结果改）
source ~/p4/p4setup.sh
which p4c simple_switch

cd ~/fisslock/switch/p4_bmv2
bash scripts/start_switch.sh
```

或指定编译器路径：

```bash
export P4C=/usr/local/bin/p4c
bash scripts/start_switch.sh
```

**`Cannot open libbmv2.so`**  
→ `sudo ldconfig`；确认 `make install` 成功

**`simple_switch_CLI` / `ModuleNotFoundError: No module named 'thrift'`**  
→ `simple_switch_CLI` 走系统 Python（如 3.12），与 p4dev venv 无关。修复后重灌组播：

```bash
# Ubuntu 24.04 勿用 sudo pip3（PEP 668）；用 apt：
sudo apt-get install -y python3-thrift
# 组播在 start_switch 时已灌；仅当 switch.log 无 mgrp(299) 时再:
bash scripts/apply_multicast.sh
# 若提示「已存在」或 mc_dump 有 mgrp(299)，说明已成功，勿重复灌（会 ERROR）
echo mc_dump | sudo simple_switch_CLI | grep -A3 mgrp
```

**测试无 pcap / `[warn] no pcap under build/pcap`**  
→ 发包 iface 必须是 **`veth-inject`**。  
→ **不要在 `start_switch` 之后 `rm build/pcap/*.pcap`**：交换机已打开旧文件句柄，删文件后不会再写新 pcap。正确顺序：

```bash
bash scripts/stop_switch.sh
sudo rm -f build/pcap/*.pcap
RESTART=1 bash scripts/start_switch.sh
bash scripts/apply_multicast.sh    # thrift 修好后
sudo /path/to/p4dev-python-venv/bin/python3 test/test_paths.py \
  --iface veth-inject --only all --pcap-dir build/pcap
```

→ 若曾删过 pcap 且未重启，用 `RESTART=1 bash scripts/start_switch.sh` 或 `bash scripts/restart_switch.sh`。

**要跑官方 C++/DPDK 全栈**  
→ 需另装 DPDK、R2 子模块等，见仓库根目录 `README.md`；BMv2 验证只需本节步骤。

---

## 八、目录速查

```
switch/p4_bmv2/
├── fisslock_bmv2.p4      # P4 程序
├── run_bmv2.sh           # 前台启动
├── scripts/
│   ├── ubuntu-install-deps.sh
│   ├── setup_veth.sh
│   ├── start_switch.sh   # 推荐：后台启动+组播
│   └── stop_switch.sh
├── setup/multicast.txt
└── test/test_paths.py    # Python 测试客户端
```
