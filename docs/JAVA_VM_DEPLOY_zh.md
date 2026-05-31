# Java 项目部署到 p4dev 虚拟机

> **完整步骤**（交换机 + Sidecar + 示例 + 抢锁 + 排错）见 **[OPERATIONS_MANUAL_zh.md](./OPERATIONS_MANUAL_zh.md)**。  
> **不懂命令时**先看操作手册 **[§0 零基础速览](./OPERATIONS_MANUAL_zh.md#0-零基础速览三个窗口每条命令在干什么)**。  
> 本文保留部署与同步要点。

## 1. 从 Windows 同步到 VM
在 **PowerShell**（改 IP/用户名）：

```powershell
scp -r D:\fisslock\java\fisslock-java subingbo@192.168.43.110:~/fisslock/java/
scp -r D:\fisslock\lib subingbo@192.168.43.110:~/fisslock/
```

或同步整个仓库后确认路径为 `~/fisslock/java/fisslock-java`。  
`lib/` 仅在使用 **C++ 后端**（`FISSLOCK_BACKEND=lib`）时需要。

在 VM 上修正脚本换行（**从 Windows `scp` 后若报 `set: -: invalid option` 或 `$'\r': command not found`，必做**）。

`fix-crlf.sh` 若也跑不起来，请**手敲**下面一行（不要 scp 脚本后再跑脚本）：

```bash
sed -i 's/\r$//' ~/fisslock/java/fisslock-java/scripts/*.sh && chmod +x ~/fisslock/java/fisslock-java/scripts/*.sh && echo OK
```

或进入目录后：

```bash
cd ~/fisslock/java/fisslock-java
sed -i 's/\r$//' scripts/*.sh && chmod +x scripts/*.sh
bash scripts/vm-run-sidecar.sh
```

## 2. VM 上一键编译

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-setup.sh
```

## 3. 启动顺序（三个终端或 tmux）

**终端 A — BMv2 交换机**

```bash
cd ~/fisslock/switch/p4_bmv2
export P4C="$HOME/tutorials/p4c-stable/build/p4c"
export PATH="$HOME/tutorials/p4c-stable/build:/usr/local/bin:$PATH"
bash scripts/stop_switch.sh
sudo rm -f build/pcap/*.pcap
RESTART=1 bash scripts/start_switch.sh
echo mc_dump | sudo simple_switch_CLI | grep -A3 'mgrp(299)'
```

**终端 B — Java Sidecar（root）**

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-sidecar.sh
```

**终端 C — Java 业务（普通用户）**

```bash
cd ~/fisslock/java/fisslock-java
bash scripts/vm-run-example.sh 1
```

成功时示例输出含 `held, critical section` / `released`。

### 3.1 阶段 0.2：C++ lib 后端 + 抢锁（可选）

```bash
# 终端 B（先编译 .so，再改后端）
cd ~/fisslock/java/fisslock-java
bash scripts/vm-build-lib.sh
export LD_LIBRARY_PATH="$HOME/fisslock/lib/bmv2:$LD_LIBRARY_PATH"
export FISSLOCK_BACKEND=lib
bash scripts/vm-run-sidecar.sh

# 终端 C（须看到 PASS:）
mvn -q -Pcontention exec:java -Dexec.args="5 500"
```

详见 [OPERATIONS_MANUAL_zh.md §5B、§10](./OPERATIONS_MANUAL_zh.md#5b-c-lib-后端联调阶段-02)。

## 4. 环境变量（可选）

| 变量 | 默认 | 含义 |
|------|------|------|
| `FISSLOCK_BACKEND` | `python` | `python`（Scapy）、`lib`（C++ `lock.cc` + JNI）、或 `pcap`（Pcap4j） |
| `FISSLOCK_PYTHON` | `~/tutorials/p4dev-python-venv/bin/python3` | Scapy 解释器 |
| `FISSLOCK_PCAP_DIR` | `~/fisslock/switch/p4_bmv2/build/pcap` | 读 GRANT 的 pcap 目录 |
| `FISSLOCK_SEND_IFACE` | `veth-inject` | 发送 ACQUIRE |
| `FISSLOCK_GRPC_PORT` | `50051` | gRPC 端口 |
| `FISSLOCK_MACHINE_ID` | `1` | 本机 host_id |

## 5. 故障排查

| 现象 | 处理 |
|------|------|
| `interface not found` | `cd ~/fisslock/switch/p4_bmv2 && sudo bash scripts/setup_veth.sh` |
| `tryLock` 失败 / gRPC UNKNOWN | 先 `bash scripts/vm-test-python-backend.sh`；确认仅 1 个 `simple_switch`；`mvn package` 后重启 Sidecar |
| `tryLock` 失败 | 交换机未起；或 Sidecar 未 sudo |
| `set: pipefail: invalid option` | 脚本为 CRLF：`bash scripts/fix-crlf.sh` 后重试 |
| `mvn: command not found` | `bash scripts/vm-setup.sh` |
| gRPC 连不上 | 先起 Sidecar；业务与 Sidecar 同在 VM 时用 `connectLocal` |

## 6. 相关文档

- [JAVA_INTEGRATION_zh.md](./JAVA_INTEGRATION_zh.md) — 架构与阶段
- [BMV2_UBUNTU_VALIDATION_zh.md](./BMV2_UBUNTU_VALIDATION_zh.md) — 交换机验证
