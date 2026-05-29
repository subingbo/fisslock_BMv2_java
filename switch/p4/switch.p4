/*
 * ============================================================================
 * FissLock Tofino 数据面 — 程序入口（Pipeline 拼装）
 * ============================================================================
 *
 * 新手请先读：switch/LEARNING_zh.md
 * 学习顺序：headers.p4 → parser.p4 → ingress.p4（含 lock/counter）→ egress.p4
 *
 * Intel Tofino 使用 TNA 架构（tna.p4），与 BMv2 单文件逻辑对齐但：
 *   - 百万级锁分 3 个 pipeline stage（CounterTable_1/2/3, LockOperation_1/2/3）
 *   - 双组播 mcast_grp_a / mcast_grp_b
 *
 * 编译：仓库根目录 configure_p4.sh fisslock_decider switch/p4/switch.p4
 * ============================================================================
 */

#include <core.p4>
#include <tna.p4>

#include "headers.p4"
#include "parser.p4"
#include "ingress.p4"
#include "egress.p4"

/*
 * Tofino 流水线六段（包依次经过）：
 *   IngressParser  → 解析 + Tofino 入口 metadata
 *   IngressPipe    → 锁逻辑、改包头、定出口/组播
 *   IngressDeparser→ 重算 IPv4 校验和并 emit
 *   EgressParser   → 出口侧再解析（组播副本）
 *   EgressPipe     → 按 egress_rid 改锁包头
 *   EgressDeparser → 发出
 */
Pipeline(
  IngressParser(),
  IngressPipe(),
  IngressDeparser(),
  EgressParser(),
  EgressPipe(),
  EgressDeparser()
) pipe;

Switch(pipe) main;
