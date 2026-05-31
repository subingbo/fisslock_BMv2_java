#!/usr/bin/env python3
"""
BMv2 锁包助手 — 与 switch/p4_bmv2/test/test_paths.py 相同 Scapy 逻辑。
供 Java Sidecar 调用，避免 Pcap4j 原生库问题。

用法:
  sudo python3 bmv2_try_acquire.py try_acquire --iface veth-inject --pcap-dir build/pcap \\
      --lock-id 1 --machine-id 1 --timeout 3
  sudo python3 bmv2_try_acquire.py free --iface veth-inject --lock-id 1 --machine-id 1

stdout 一行 JSON；exit 0=granted, 1=失败
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
import time
from pathlib import Path

try:
    from scapy.all import Ether, IP, UDP, Raw, sendp, rdpcap
except ImportError:
    sys.stderr.write("scapy required\n")
    sys.exit(2)

UDP_PORT_SERVER = 20001
UDP_PORT_CLIENT = 20002
ACQUIRE = 0x01
GRANT_W_AGENT = 0x02
FREE = 0x06
LOCK_EXCL = 1

PCAP_OUT = [
    "veth-switch_out.pcap",
    "veth-h1_out.pcap",
    "veth-h2_out.pcap",
]


def mode_old_mode(mode: int, old_mode: int = 0) -> int:
    return ((old_mode & 1) << 1) | (mode & 1)


def build_lock_packet(typ: int, mode: int, lock_id: int, machine_id: int, ncnt: int = 0):
    payload = struct.pack(
        "!BBIIBIBB",
        typ,
        mode_old_mode(mode, 0),
        lock_id,
        machine_id,
        0,
        0,
        0,
        ncnt,
    )
    pkt = (
        Ether(dst="00:00:00:00:01:00", src="00:00:00:00:00:01")
        / IP(src="10.0.0.1", dst="10.0.0.2")
        / UDP(sport=30000, dport=UDP_PORT_SERVER)
        / Raw(load=payload)
    )
    del pkt[IP].chksum
    del pkt[UDP].chksum
    return pkt.__class__(bytes(pkt))


def parse_lock_payload(raw: bytes) -> dict | None:
    if len(raw) < 17:
        return None
    typ = raw[0]
    mom = raw[1]
    lid, mid, _, agent, _, ncnt = struct.unpack("!IIBIBB", raw[2:17])
    return {
        "type": typ,
        "granted": (mom >> 6) & 1,
        "id": lid,
        "machine_id": mid,
        "agent": agent,
        "ncnt": ncnt,
    }


def total_pcap_bytes(pcap_dir: Path) -> int:
    n = 0
    for name in PCAP_OUT:
        p = pcap_dir / name
        if p.exists():
            n += p.stat().st_size
    return n


def find_grant(pcap_dir: Path, lock_id: int) -> dict | None:
    pcaps = sorted(pcap_dir.glob("*.pcap"))
    prefer = [
        "veth-switch_out",
        "veth-h1_out",
        "veth-h2_out",
        "veth-switch_in",
    ]
    ordered = [pcap_dir / (n + ".pcap") for n in prefer if (pcap_dir / (n + ".pcap")).exists()]
    ordered += [p for p in pcaps if p not in ordered]
    latest = None
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
            if not info:
                continue
            if info["type"] in (GRANT_W_AGENT, 3) and info["id"] == lock_id:
                latest = {"type": info["type"], "lock_id": lock_id, "dport": dport}
    return latest


def cmd_try_acquire(args) -> int:
    pcap_dir = Path(args.pcap_dir)
    timeout = max(0.5, float(args.timeout))
    lock_id = int(args.lock_id)
    machine_id = int(args.machine_id)
    before = total_pcap_bytes(pcap_dir)
    pkt = build_lock_packet(ACQUIRE, LOCK_EXCL, lock_id, machine_id)
    sendp(pkt, iface=args.iface, verbose=False)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if total_pcap_bytes(pcap_dir) > before:
            g = find_grant(pcap_dir, lock_id)
            if g:
                out = {
                    "granted": True,
                    "with_agent": g["type"] == GRANT_W_AGENT,
                    "lock_id": lock_id,
                    "grant_type": g["type"],
                }
                print(json.dumps(out))
                return 0
        time.sleep(0.08)
    print(json.dumps({"granted": False, "error": "timeout", "lock_id": lock_id}))
    return 1


def cmd_free(args) -> int:
    pkt = build_lock_packet(FREE, LOCK_EXCL, int(args.lock_id), int(args.machine_id))
    sendp(pkt, iface=args.iface, verbose=False)
    print(json.dumps({"ok": True}))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_try = sub.add_parser("try_acquire")
    p_try.add_argument("--iface", default="veth-inject")
    p_try.add_argument("--pcap-dir", required=True)
    p_try.add_argument("--lock-id", type=int, required=True)
    p_try.add_argument("--machine-id", type=int, default=1)
    p_try.add_argument("--timeout", type=float, default=3.0)

    p_free = sub.add_parser("free")
    p_free.add_argument("--iface", default="veth-inject")
    p_free.add_argument("--lock-id", type=int, required=True)
    p_free.add_argument("--machine-id", type=int, default=1)

    args = ap.parse_args()
    if args.cmd == "try_acquire":
        return cmd_try_acquire(args)
    if args.cmd == "free":
        return cmd_free(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
