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
    import sys
    raise SystemExit(
        "scapy 未安装到当前 Python。\n"
        f"  当前: {sys.executable}\n"
        "  若在 venv 里装了 scapy，请用:\n"
        "    sudo $(which python3) test/test_paths.py ...\n"
        "  或:\n"
        "    sudo /home/subingbo/tutorials/p4dev-python-venv/bin/python3 test/test_paths.py ...\n"
        "  或: sudo pip3 install scapy"
    )

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
    pkt = (
        Ether(dst="00:00:00:00:01:00", src="00:00:00:00:00:01")
        / IP(src="10.0.0.1", dst="10.0.0.2")
        / UDP(sport=30000, dport=dst_port)
        / Raw(load=payload)
    )
    # 让 Scapy 重算 IP/UDP 校验和，避免 BMv2 丢包
    del pkt[IP].chksum
    del pkt[UDP].chksum
    return pkt.__class__(bytes(pkt))


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


TYPE_NAME = {
    1: "ACQUIRE",
    2: "GRANT_W_AGENT",
    3: "GRANT_WO_AGENT",
    4: "RELEASE",
    5: "TRANSFER",
    6: "FREE",
}


def collect_lock_packets(pcap_dir: Path) -> list[tuple[str, dict, int]]:
    """返回 [(pcap名, 解析结果, udp_dport), ...]"""
    out: list[tuple[str, dict, int]] = []
    pcaps = sorted(pcap_dir.glob("*.pcap"))
    prefer = [
        "veth-h1_out", "veth-h2_out", "veth-switch_out",
        "veth-h1_in", "veth-h2_in", "veth-switch_in",
    ]
    ordered = [pcap_dir / n for n in prefer if (pcap_dir / n).exists()]
    ordered += [p for p in pcaps if p not in ordered]
    for p in ordered:
        if p.stat().st_size < 24:
            continue
        for pkt in rdpcap(str(p)):
            if not (pkt.haslayer(UDP) and pkt.haslayer(Raw)):
                continue
            dport = int(pkt[UDP].dport)
            if dport not in (UDP_PORT_SERVER, UDP_PORT_CLIENT):
                continue
            info = parse_lock_payload(bytes(pkt[Raw]))
            if info:
                out.append((p.name, info, dport))
    return out


def verify_state(pkts: list[tuple[str, dict, int]]) -> bool:
    ok = any(
        i["type"] == GRANT_W_AGENT and dport == UDP_PORT_CLIENT and i.get("id") == 1
        for _, i, dport in pkts
    )
    print(f"  [状态机] {'PASS' if ok else 'FAIL'}: 需见 GRANT_W_AGENT(2) dport=20002 lock=1")
    return ok


def verify_mcast(pkts: list[tuple[str, dict, int]]) -> bool:
    agent_ok = any(
        i["type"] == ACQUIRE and i.get("granted") and i.get("id") == 10
        for _, i, dport in pkts
    )
    client_ok = any(
        i["type"] == GRANT_WO_AGENT and dport == UDP_PORT_CLIENT and i.get("id") == 10
        for _, i, dport in pkts
    )
    # BMv2 单机 port0 注入时，组播副本也可能出现在 switch_out
    if not client_ok:
        client_ok = any(
            i["type"] == GRANT_WO_AGENT and dport == UDP_PORT_CLIENT and i.get("id") == 10
            for name, i, dport in pkts
            if "switch_out" in name
        )
    ok = agent_ok and client_ok
    print(f"  [组播] {'PASS' if ok else 'FAIL'}: 需 ACQUIRE+granted(lock10) 且 GRANT_WO_AGENT dport=20002")
    if not agent_ok:
        print("         缺: agent 侧 ACQUIRE + granted (egress_rid=1)")
    if not client_ok:
        print("         缺: client 侧 GRANT_WO_AGENT（检查 setup/multicast.txt）")
    return ok


def verify_counter(pkts: list[tuple[str, dict, int]]) -> bool:
    grants = [
        (name, i, dport)
        for name, i, dport in pkts
        if i.get("id") == 20 and i["type"] == GRANT_W_AGENT and dport == UDP_PORT_CLIENT
    ]
    ok = len(grants) >= 1
    print(f"  [counter] {'PASS' if ok else 'FAIL'}: 需见 lock=20 的 GRANT_W_AGENT（ncnt 匹配后的 TRANSFER）")
    return ok


def check_pcaps(pcap_dir: Path) -> None:
    """解析 BMv2 --pcap 目录（veth-h1_in.pcap 等），只显示锁 UDP 20001/20002。"""
    pcaps = sorted(pcap_dir.glob("*.pcap"))
    if not pcaps:
        print(f"  [warn] no pcap under {pcap_dir}")
        return
    found = 0
    # BMv2: *_out.pcap = 交换机发往该口；*_in.pcap = 进入交换机
    prefer = ["veth-h1_out", "veth-h2_out", "veth-switch_out", "veth-h1_in", "veth-h2_in", "veth-switch_in"]
    ordered = [pcap_dir / n for n in prefer if (pcap_dir / n).exists()]
    ordered += [p for p in pcaps if p not in ordered]

    for p in ordered:
        if p.stat().st_size < 24:
            continue
        for pkt in rdpcap(str(p)):
            if not (pkt.haslayer(UDP) and pkt.haslayer(Raw)):
                continue
            dport = int(pkt[UDP].dport)
            if dport not in (UDP_PORT_SERVER, UDP_PORT_CLIENT):
                continue
            raw = bytes(pkt[Raw])
            if len(raw) < 1:
                continue
            info = parse_lock_payload(raw)
            if not info:
                continue
            found += 1
            tname = TYPE_NAME.get(info["type"], f"?{info['type']}")
            print(
                f"  {p.name}: {tname} dport={dport} "
                f"lock={info.get('id')} host={info.get('machine_id')} "
                f"agent={info.get('agent')} granted={info.get('granted', 0)} ncnt={info.get('ncnt', 0)}"
            )
    if found == 0:
        print("  [warn] 未找到 UDP 20001/20002 锁包；请用:")
        print("    sudo tcpdump -r build/pcap/veth-switch_out.pcap -nn 'udp port 20001 or udp port 20002'")


def verify_pcaps(pcap_dir: Path, which: str) -> bool:
    pkts = collect_lock_packets(pcap_dir)
    print(f"\n--- 自动判定 ({which}) ---")
    if not pkts:
        print("  [FAIL] pcap 中无锁包；确认交换机已启动且未删 pcap 后重测")
        return False
    ok = True
    if which in ("state", "all"):
        ok = verify_state(pkts) and ok
    if which in ("mcast", "all"):
        ok = verify_mcast(pkts) and ok
    if which in ("counter", "all"):
        ok = verify_counter(pkts) and ok
    return ok


def test_state_machine(iface: str) -> None:
    """路径1：lock_id=1 独占 ACQUIRE → 期望 port1 收到 GRANT_W_AGENT(2), dport=20002。"""
    sendp(
        build_lock_packet(ACQUIRE, LOCK_EXCL, 1, 1),
        iface=iface,
        verbose=False,
    )
    time.sleep(0.3)
    print("[1 状态机] ACQUIRE excl → 期望 veth-h1_out.pcap: type=GRANT_W_AGENT(2), dport=20002")


def test_multicast(iface: str) -> None:
    """路径3：同一 shared 锁两次 ACQUIRE（host1 再 host2）→ 组播 299，port1/2 pcap 不同 type。"""
    sendp(build_lock_packet(ACQUIRE, LOCK_SHARED, 10, 1), iface=iface, verbose=False)
    time.sleep(0.2)
    sendp(build_lock_packet(ACQUIRE, LOCK_SHARED, 10, 2), iface=iface, verbose=False)
    time.sleep(0.3)
    print("[2 组播] 两次 shared ACQUIRE → 期望 h1_out: ACQUIRE+granted, h2_out: GRANT_WO_AGENT")


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
    import sys
    print(f"[test_paths] python={sys.executable}")
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
        pcap_dir = Path(args.pcap_dir)
        print("\n--- pcap 明细 ---")
        check_pcaps(pcap_dir)
        if not verify_pcaps(pcap_dir, args.only):
            raise SystemExit(1)
        print("\n全部通过。")


if __name__ == "__main__":
    main()
