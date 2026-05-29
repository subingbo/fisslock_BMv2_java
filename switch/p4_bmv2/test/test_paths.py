#!/usr/bin/env python3
"""
FissLock BMv2 — 三条数据面路径的功能测试（Scapy 发 UDP 锁包）

新手导读：switch/LEARNING_zh.md 第 3 节

与 lib/post.h 一致：UDP payload = post_header(1B type) + lock_post_header(16B) = 17 字节

依赖:
  - 交换机已运行（scripts/start_switch.sh）
  - 已灌组播表 setup/multicast.txt
  - scapy: pip install scapy

用法:
  sudo python3 test_paths.py --iface veth-inject
  sudo python3 test_paths.py --iface veth-inject --pcap-dir build/pcap
  sudo python3 test_paths.py --only state   # 仅测状态机

三条测试与 P4 表对应关系:
  test_state_machine  → lock_op_table op_new_agent（独占首次 ACQUIRE）
  test_multicast      → op_mcast_to_agent + egress rid 1/2（共享二次 ACQUIRE）
  test_counter        → counter_table cnt_cmp（TRANSFER 时 ncnt 须匹配）
"""

from __future__ import annotations

import argparse
import struct
import time
from pathlib import Path

try:
    from scapy.all import Ether, IP, UDP, Raw, sendp, rdpcap
except ImportError:
    raise SystemExit("pip install scapy")

UDP_PORT_SERVER = 20001
UDP_PORT_CLIENT = 20002

ACQUIRE = 0x01
GRANT_W_AGENT = 0x02
GRANT_WO_AGENT = 0x03
TRANSFER = 0x05

LOCK_SHARED = 0
LOCK_EXCL = 1


def mode_old_mode(mode: int, old_mode: int = 0) -> int:
    return ((old_mode & 1) << 1) | (mode & 1)


def build_lock_packet(
    typ: int,
    mode: int,
    lock_id: int,
    machine_id: int,
    dst_port: int = UDP_PORT_SERVER,
    old_mode: int = 0,
    ncnt: int = 0,
    agent: int = 0,
    wq_size: int = 0,
) -> Ether:
    """构造 17 字节锁 UDP 包（type + lock_post_header），dport 默认 20001 触发 P4 parse_lock。"""
    payload = struct.pack(
        "!BBIIBIBB",
        typ,
        mode_old_mode(mode, old_mode),
        lock_id,
        machine_id,
        0,
        agent,
        wq_size,
        ncnt,
    )
    assert len(payload) == 17
    return (
        Ether(dst="00:00:00:00:01:00", src="00:00:00:00:00:01")
        / IP(src="10.0.0.1", dst="10.0.0.2")
        / UDP(sport=30000, dport=dst_port)
        / Raw(load=payload)
    )


def parse_lock_payload(raw: bytes) -> dict | None:
    if len(raw) < 2:
        return None
    typ = raw[0]
    mom = raw[1]
    if len(raw) < 17:
        return {"type": typ, "mode_old_mode": mom}
    lid, mid, _, agent, _, ncnt = struct.unpack("!IIBIBB", raw[2:17])
    return {
        "type": typ,
        "mode": mom & 1,
        "old_mode": (mom >> 1) & 1,
        "granted": (mom >> 6) & 1,
        "id": lid,
        "machine_id": mid,
        "agent": agent,
        "ncnt": ncnt,
    }


def check_pcaps(pcap_dir: Path) -> None:
    for port in (1, 2):
        p = pcap_dir / f"{port}.pcap"
        if not p.exists():
            print(f"  [warn] missing {p}")
            continue
        for pkt in rdpcap(str(p)):
            if pkt.haslayer(UDP) and pkt.haslayer(Raw):
                info = parse_lock_payload(bytes(pkt[Raw]))
                if info:
                    print(f"  port {port}: type={info['type']} dport={pkt[UDP].dport} {info}")


def test_state_machine(iface: str) -> None:
    """路径1：lock_id=1 独占 ACQUIRE → 期望 port1 收到 GRANT_W_AGENT(2), dport=20002。"""
    sendp(
        build_lock_packet(ACQUIRE, LOCK_EXCL, 1, 1),
        iface=iface,
        verbose=False,
    )
    time.sleep(0.3)
    print("[1 状态机] ACQUIRE excl → 期望 port1 pcap: type=GRANT_W_AGENT(2), dport=20002")


def test_multicast(iface: str) -> None:
    """路径3：同一 shared 锁两次 ACQUIRE（host1 再 host2）→ 组播 299，port1/2 pcap 不同 type。"""
    sendp(build_lock_packet(ACQUIRE, LOCK_SHARED, 10, 1), iface=iface, verbose=False)
    time.sleep(0.2)
    sendp(build_lock_packet(ACQUIRE, LOCK_SHARED, 10, 2), iface=iface, verbose=False)
    time.sleep(0.3)
    print("[2 组播] 两次 shared ACQUIRE → 期望 port1: ACQUIRE+granted, port2: GRANT_WO_AGENT")


def test_counter(iface: str) -> None:
    """路径2：先 ACQUIRE 使 ncnt=1；TRANSFER ncnt=0 应失败；ncnt=1 应 transfer_agent 成功。"""
    sendp(build_lock_packet(ACQUIRE, LOCK_SHARED, 20, 1), iface=iface, verbose=False)
    time.sleep(0.2)
    sendp(
        build_lock_packet(TRANSFER, LOCK_SHARED, 20, 2, old_mode=LOCK_SHARED, ncnt=0),
        iface=iface,
        verbose=False,
    )
    time.sleep(0.2)
    sendp(
        build_lock_packet(TRANSFER, LOCK_SHARED, 20, 2, old_mode=LOCK_SHARED, ncnt=1),
        iface=iface,
        verbose=False,
    )
    time.sleep(0.3)
    print("[3 counter] 先 stale ncnt=0 再 ncnt=1 → 第二次 TRANSFER 应 grant agent")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="veth-inject", help="连接 BMv2 port0 对端 veth（setup_veth 创建的 veth-inject）")
    ap.add_argument("--pcap-dir", default="", help="simple_switch -pcap 输出目录")
    ap.add_argument("--only", choices=["state", "mcast", "counter", "all"], default="all")
    args = ap.parse_args()

    if args.only in ("state", "all"):
        test_state_machine(args.iface)
    if args.only in ("mcast", "all"):
        test_multicast(args.iface)
    if args.only in ("counter", "all"):
        test_counter(args.iface)

    if args.pcap_dir:
        print("\n--- pcap 检查 ---")
        check_pcaps(Path(args.pcap_dir))


if __name__ == "__main__":
    main()
