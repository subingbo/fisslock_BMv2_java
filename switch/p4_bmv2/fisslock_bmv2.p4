/*
 * ============================================================================
 * FissLock BMv2 数据面（v1model）— 功能验证用单文件实现
 * ============================================================================
 *
 * 新手请先读：switch/LEARNING_zh.md
 *
 * 本文件验证论文三条核心路径：
 *   1. 锁裂变状态机：lock_free / lock_rw + agent（lock_op_table）
 *   2. Counter 一致性：notification_cnt 与包内 ncnt（counter_table）
 *   3. 共享锁组播授权：mcast_to_agent → egress 按 egress_rid 改包
 *
 * 流水线：Parser → Ingress → Egress → Deparser → V1Switch(main)
 *
 * 拓扑（README）：
 *   port 0 = 注入口（veth-switch，测试用 veth-inject）
 *   port 1 = host1（常作 agent）
 *   port 2 = host2（常作 client）
 *
 * 与 Tofino 版差异见 LEARNING_zh.md 第 6 节；逻辑对齐但锁仅 1024 把、单组播组 299。
 * ============================================================================
 */

#include <core.p4>
#include <v1model.p4>

// ----- 基础类型别名 -----
typedef bit<48> mac_addr_t;
typedef bit<32> ipv4_addr_t;
typedef bit<16> udp_port_t;
typedef bit<32> lid_t;   // lock id（锁编号）
typedef bit<8>  host_t;  // 主机编号 machine_id / agent

const bit<16> TYPE_IPV4 = 0x0800;
const bit<8>  TYPE_UDP  = 17;

// 锁业务 UDP 端口：20001 发往 server/agent，20002 发往 client
const udp_port_t UDP_PORT_SERVER = 20001;
const udp_port_t UDP_PORT_CLIENT = 20002;

// ----- 锁消息类型（与 lib/post.h POST_LOCK_* 一致）-----
const bit<8> ACQUIRE        = 0x01;  // 申请锁
const bit<8> GRANT_W_AGENT  = 0x02;  // 授权且请求者成为 agent
const bit<8> GRANT_WO_AGENT = 0x03;  // 授权但 agent 在其它主机
const bit<8> RELEASE        = 0x04;  // 释放（共享）
const bit<8> TRANSFER       = 0x05;  // 转移 agent
const bit<8> FREE           = 0x06;  // 释放锁（独占结束）

// ----- 锁在交换机寄存器中的状态取值 -----
const bit<1> LOCK_FREE     = 0;  // 锁未被占用
const bit<1> LOCK_ACQUIRED = 1;  // 锁已被 acquire
const bit<1> LOCK_SHARED   = 0;  // 共享模式
const bit<1> LOCK_EXCL     = 1;  // 独占模式

/* BMv2 测试规模：单 slice，1024 把锁（id 0..1023，id 右移 10 位须为 0） */
const bit<32> SLICE_SIZE_POW2 = 10;
const bit<32> SLICE_MASK      = 0x3FF;           /* 1024 locks: id & SLICE_MASK */
const bit<32> SLICE_HIGH_MASK = 32w0xFFFFFC00; /* id 超出 slice 时高位非 0（BMv2 禁止 >>10） */
const bit<16> MCAST_SHARED_GRANT = 299;  // 共享锁二次 ACQUIRE 使用的组播组 ID

// ----- 标准 L2/L3/L4 包头（简化，无 RoCE）-----
header ethernet_t {
    mac_addr_t dst_addr;
    mac_addr_t src_addr;
    bit<16>    ether_type;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> total_len;
    bit<16> identification;
    bit<3>  flags;
    bit<13> frag_offset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdr_checksum;
    ipv4_addr_t src_addr;
    ipv4_addr_t dst_addr;
}

header udp_t {
    bit<16> src_port;
    bit<16> dst_port;
    bit<16> length;
    bit<16> checksum;
}

/*
 * FissLock 锁头（UDP payload 前 17 字节，字段布局见 lib/post.h）
 * 注意：P4 里把 type 单独成字段；主机栈可能 pack 在 post_header + lock_post_header
 */
/* 与 lib/post.h 逐字节一致（共 17 字节），勿用 bit<1> 打包以免 P4 头长度错位 */
header lock_hdr_t {
    bit<8>  type;
    bit<8>  mode_old_mode;  /* bit0=mode, bit1=old_mode; bit5=transferred; bit6=granted */
    bit<32> id;
    bit<8>  machine_id;
    bit<32> task_id;
    bit<8>  agent;
    bit<32> wq_size;
    bit<8>  ncnt;
}

/* 流水线 metadata：不写入发出的包，仅在 Ingress/Egress 间传递 */
struct metadata {
    bit<16> dest2;              // 组播第二目标（mcast_to_agent 时 = machine_id）
    bit<1>  lock_free_mode;     // acquire 前读到的空闲状态
    bit<1>  lock_rw_mode;       // 当前 shared/excl
    bit<8>  lock_agent;        // 待写入 agent 寄存器的值
    bit<32> lock_index;        // 寄存器索引 = id & SLICE_MASK
    bit<1>  agent_changed;     // counter 比较是否通过（1=可更新 agent）
    bit<1>  lock_out_of_range; // id 超出 1024
    bit<8>  fwd_host;          // host_fwd 查表键
    bit<1>  pkt_mode;          // mode_old_mode[0]
    bit<1>  pkt_old_mode;      // mode_old_mode[1]
    bit<1>  multicasted;       // 组播路径标记（不写回包头）
}

struct headers {
    ethernet_t  ethernet;
    ipv4_t      ipv4;
    udp_t       udp;
    lock_hdr_t  lock;
}

/*
 * ============================================================================
 * Parser：从 packet_in 提取各层 header
 * ============================================================================
 * 锁包路径：ethernet → ipv4 → udp → (dport 20001/20002) → lock
 */
parser FissParser(packet_in packet,
              out headers hdr,
              inout metadata meta,
              inout standard_metadata_t standard_metadata) {
    state start {
        transition parse_ethernet;
    }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            TYPE_IPV4: parse_ipv4;
            default: accept;  // 非 IPv4 不再解析，ingress 不处理锁
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            TYPE_UDP: parse_udp;
            default: accept;
        }
    }
    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dst_port) {
            UDP_PORT_SERVER: parse_lock;
            UDP_PORT_CLIENT: parse_lock;
            default: accept;
        }
    }
    state parse_lock {
        packet.extract(hdr.lock);
        transition accept;  // hdr.lock.isValid() == true
    }
}

/*
 * ============================================================================
 * Ingress：锁逻辑核心（查表 + 改寄存器 + 改包头 + 定出口）
 * ============================================================================
 */
control FissIngress(inout headers hdr, inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    // 每把锁一片寄存器，索引 meta.lock_index（0..1023）
    register<bit<1>>(1024) lock_free_reg;       // 0=FREE 1=ACQUIRED
    register<bit<1>>(1024) lock_rw_reg;         // SHARED/EXCL
    register<bit<8>>(1024) lock_agent_reg;      // agent host_id
    register<bit<8>>(1024) notification_cnt_reg; // 共享锁通知计数

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action set_egress(bit<9> port) {
        standard_metadata.egress_spec = port;  // BMv2 单播出口
    }

    // --- 空闲寄存器：acquire 读旧值并写 ACQUIRED；FREE 时 release ---
    action do_acquire() {
        bit<32> idx = meta.lock_index;
        bit<1> st;
        lock_free_reg.read(st, idx);
        meta.lock_free_mode = st;           // 供 lock_op_table 匹配「原先是否空闲」
        lock_free_reg.write(idx, LOCK_ACQUIRED);
    }

    action do_release() {
        bit<32> idx = meta.lock_index;
        bit<1> st;
        lock_free_reg.read(st, idx);
        meta.lock_free_mode = st;
        lock_free_reg.write(idx, LOCK_FREE);
    }

    // --- 读写模式寄存器（rw_table 调用）---
    action rw_set_shared() {
        bit<32> idx = meta.lock_index;
        bit<1> st;
        lock_rw_reg.read(st, idx);
        meta.lock_rw_mode = st;
        lock_rw_reg.write(idx, LOCK_SHARED);
    }

    action rw_set_excl() {
        bit<32> idx = meta.lock_index;
        bit<1> st;
        lock_rw_reg.read(st, idx);
        meta.lock_rw_mode = st;
        lock_rw_reg.write(idx, LOCK_EXCL);
    }

    action rw_get_mode() {
        bit<32> idx = meta.lock_index;
        lock_rw_reg.read(meta.lock_rw_mode, idx);
    }

    // --- 通知计数（路径 2：counter 一致性）---
    action cnt_new() {
        bit<32> idx = meta.lock_index;
        bit<8> val;
        notification_cnt_reg.read(val, idx);
        val = val + 1;
        notification_cnt_reg.write(idx, val);
    }

    action cnt_reset() {
        bit<32> idx = meta.lock_index;
        notification_cnt_reg.write(idx, 0);
    }

    /* BMv2: 禁止 action 内条件写 register；只比较，清零交给 counter_clear_table */
    action cnt_cmp_eval() {
        bit<32> idx = meta.lock_index;
        bit<8> val;
        notification_cnt_reg.read(val, idx);
        meta.agent_changed = (bit<1>)(val == hdr.lock.ncnt);
    }

    action cnt_nop() {}

    table counter_table {
        key = { hdr.lock.type: exact; meta.pkt_mode: exact; meta.pkt_old_mode: exact; }
        actions = { cnt_new; cnt_cmp_eval; cnt_reset; cnt_nop; }
        const entries = {
            (ACQUIRE, LOCK_SHARED, 0): cnt_new();
            (ACQUIRE, LOCK_SHARED, 1): cnt_new();
            (TRANSFER, LOCK_SHARED, LOCK_SHARED): cnt_cmp_eval();
            (TRANSFER, LOCK_SHARED, LOCK_EXCL): cnt_reset();
            (TRANSFER, LOCK_EXCL, LOCK_SHARED): cnt_cmp_eval();
            (TRANSFER, LOCK_EXCL, LOCK_EXCL): cnt_reset();
            (FREE, LOCK_SHARED, LOCK_SHARED): cnt_cmp_eval();
            (FREE, LOCK_SHARED, LOCK_EXCL): cnt_reset();
            (FREE, LOCK_EXCL, LOCK_SHARED): cnt_cmp_eval();
            (FREE, LOCK_EXCL, LOCK_EXCL): cnt_reset();
        }
        default_action = cnt_nop();
    }

    table counter_clear_table {
        key = { meta.agent_changed: exact; }
        actions = { cnt_reset; cnt_nop; }
        const entries = {
            1: cnt_reset();
        }
        default_action = cnt_nop();
    }

    action agent_write() {
        lock_agent_reg.write(meta.lock_index, meta.lock_agent);
    }

    // ----- 锁裂变状态机五类 action（路径 1）-----
    action op_new_agent() {
        agent_write();
        hdr.lock.agent = hdr.lock.machine_id;
        hdr.lock.type = GRANT_W_AGENT;
        hdr.udp.dst_port = UDP_PORT_CLIENT;
        hdr.lock.mode_old_mode = hdr.lock.mode_old_mode & 8w0xDF;
    }

    /* 共享锁已占用时再次 ACQUIRE：组播通知 agent + 新 client（路径 3） */
    action op_mcast_to_agent() {
        meta.dest2 = (bit<16>)hdr.lock.machine_id;
        meta.multicasted = 1;
        bit<8> ag;
        lock_agent_reg.read(ag, meta.lock_index);
        hdr.lock.agent = ag;
        hdr.lock.type = GRANT_WO_AGENT;  // egress 会按 rid 再改
    }

    action op_fwd_to_agent() {
        bit<8> ag;
        lock_agent_reg.read(ag, meta.lock_index);
        hdr.lock.agent = ag;
        hdr.udp.dst_port = UDP_PORT_SERVER;
    }

    action op_transfer_agent() {
        agent_write();
        hdr.lock.agent = hdr.lock.machine_id;
        hdr.lock.type = GRANT_W_AGENT;
        hdr.udp.dst_port = UDP_PORT_CLIENT;
        hdr.lock.mode_old_mode = hdr.lock.mode_old_mode | 8w0x20;
    }

    action op_reset_agent() {
        meta.lock_agent = 0;
        lock_agent_reg.write(meta.lock_index, 0);
        hdr.lock.agent = 0;
    }

    action op_nop() {}

    table lock_op_table {
        key = {
            hdr.lock.type: exact;
            meta.pkt_mode: exact;
            meta.lock_free_mode: exact;
            meta.lock_rw_mode: exact;
        }
        actions = {
            op_new_agent; op_mcast_to_agent; op_fwd_to_agent;
            op_transfer_agent; op_reset_agent; op_nop;
        }
        const entries = {
            // 锁空闲：首次 ACQUIRE → 成为 agent 并 GRANT_W_AGENT
            (ACQUIRE, LOCK_SHARED, LOCK_FREE, 0): op_new_agent();
            (ACQUIRE, LOCK_SHARED, LOCK_FREE, 1): op_new_agent();
            (ACQUIRE, LOCK_EXCL, LOCK_FREE, 0): op_new_agent();
            (ACQUIRE, LOCK_EXCL, LOCK_FREE, 1): op_new_agent();
            // 已占用：shared+shared 再次 ACQUIRE → 组播；其余 → 转给原 agent
            (ACQUIRE, LOCK_SHARED, LOCK_ACQUIRED, LOCK_SHARED): op_mcast_to_agent();
            (ACQUIRE, LOCK_SHARED, LOCK_ACQUIRED, LOCK_EXCL): op_fwd_to_agent();
            (ACQUIRE, LOCK_EXCL, LOCK_ACQUIRED, LOCK_SHARED): op_fwd_to_agent();
            (ACQUIRE, LOCK_EXCL, LOCK_ACQUIRED, LOCK_EXCL): op_fwd_to_agent();
            (RELEASE, 0, LOCK_ACQUIRED, LOCK_SHARED): op_fwd_to_agent();
            (RELEASE, 0, LOCK_ACQUIRED, LOCK_EXCL): op_fwd_to_agent();
            (TRANSFER, LOCK_SHARED, LOCK_ACQUIRED, LOCK_SHARED): op_transfer_agent();
            (TRANSFER, LOCK_SHARED, LOCK_ACQUIRED, LOCK_EXCL): op_transfer_agent();
            (TRANSFER, LOCK_EXCL, LOCK_ACQUIRED, LOCK_SHARED): op_transfer_agent();
            (TRANSFER, LOCK_EXCL, LOCK_ACQUIRED, LOCK_EXCL): op_transfer_agent();
            (FREE, LOCK_SHARED, LOCK_ACQUIRED, LOCK_SHARED): op_reset_agent();
            (FREE, LOCK_SHARED, LOCK_ACQUIRED, LOCK_EXCL): op_reset_agent();
            (FREE, LOCK_EXCL, LOCK_ACQUIRED, LOCK_SHARED): op_reset_agent();
            (FREE, LOCK_EXCL, LOCK_ACQUIRED, LOCK_EXCL): op_reset_agent();
        }
        default_action = op_nop();
    }

    table rw_table {
        key = { hdr.lock.type: exact; meta.lock_free_mode: exact; meta.pkt_mode: exact; }
        actions = { rw_set_shared; rw_set_excl; rw_get_mode; op_nop; }
        const entries = {
            (TRANSFER, LOCK_ACQUIRED, LOCK_SHARED): rw_set_shared();
            (TRANSFER, LOCK_ACQUIRED, LOCK_EXCL): rw_set_excl();
            (FREE, LOCK_ACQUIRED, LOCK_SHARED): rw_set_shared();
            (FREE, LOCK_ACQUIRED, LOCK_EXCL): rw_set_excl();
            (ACQUIRE, LOCK_FREE, LOCK_SHARED): rw_set_shared();
            (ACQUIRE, LOCK_FREE, LOCK_EXCL): rw_set_excl();
            (ACQUIRE, LOCK_ACQUIRED, LOCK_SHARED): rw_get_mode();
            (ACQUIRE, LOCK_ACQUIRED, LOCK_EXCL): rw_get_mode();
        }
        default_action = op_nop();
    }

    /* 单播：host_id → BMv2 端口号（与 multicast.txt 中 1→port1, 2→port2 一致） */
    table host_fwd {
        key = { meta.fwd_host: exact; }
        actions = { set_egress; drop; }
        const entries = {
            1: set_egress(1);
            2: set_egress(2);
        }
        default_action = drop();
    }

    apply {
        if (hdr.lock.isValid()) {

            // ① 初始化 per-packet 元数据
            meta.dest2 = 0;
            meta.agent_changed = 0;
            meta.lock_out_of_range = 0;
            meta.multicasted = 0;
            meta.pkt_mode = hdr.lock.mode_old_mode[0:0];
            meta.pkt_old_mode = hdr.lock.mode_old_mode[1:1];

            meta.lock_index = hdr.lock.id & SLICE_MASK;
            if ((hdr.lock.id & SLICE_HIGH_MASK) != 0) {
                meta.lock_out_of_range = 1;
            }

            if (meta.lock_out_of_range == 0) {
                // ② 通知计数（比较与清零分两张表，满足 BMv2 无条件写 register）
                counter_table.apply();
                counter_clear_table.apply();

                // ③ 决策树：是否在途旧包 / 是否 agent 转发的 GRANT_WO_AGENT
                if ((hdr.lock.type == TRANSFER || hdr.lock.type == FREE) &&
                    meta.pkt_old_mode == LOCK_SHARED && meta.agent_changed == 0) {
                    /* stale in-flight：跳过 lock op，仅按 hdr.lock.agent 转发 */
                } else if (hdr.lock.type == GRANT_WO_AGENT) {
                    hdr.lock.agent = hdr.lock.machine_id;
                } else {
                    // ④ 更新 free/rw 寄存器 + 状态机
                    if (hdr.lock.type != FREE) {
                        do_acquire();
                    } else {
                        do_release();
                    }
                    rw_table.apply();
                    meta.lock_agent = hdr.lock.machine_id;
                    lock_op_table.apply();
                }
            }

            // ⑤ 转发：组播或单播（host_id 与 BMv2 port 号一致：1→port1, 2→port2）
            if (meta.multicasted == 1) {
                standard_metadata.mcast_grp = MCAST_SHARED_GRANT;
            } else {
                bit<8> eg = hdr.lock.agent;
                if (eg == 0) {
                    eg = hdr.lock.machine_id;
                }
                standard_metadata.egress_spec = (bit<9>)eg;
            }
        }
    }
}

/*
 * ============================================================================
 * Egress：组播副本差异化改包（路径 3）
 * ============================================================================
 * simple_switch 为组播 299 复制两份：egress_rid=1 → agent，rid=2 → client
 */
control FissEgress(inout headers hdr, inout metadata meta,
               inout standard_metadata_t standard_metadata) {
    apply {
        if (hdr.lock.isValid() && meta.multicasted == 1) {
            if (standard_metadata.egress_rid == 2) {
                hdr.lock.type = GRANT_WO_AGENT;
                hdr.udp.dst_port = UDP_PORT_CLIENT;
                meta.multicasted = 0;
            } else if (standard_metadata.egress_rid == 1) {
                hdr.lock.type = ACQUIRE;
                hdr.udp.dst_port = UDP_PORT_SERVER;
                meta.multicasted = 0;
                hdr.lock.mode_old_mode = hdr.lock.mode_old_mode | 8w0x40;
            }
        }
    }
}

control FissVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control FissComputeChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control FissDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.lock);
    }
}

/* p4c 1.2.x v1model 需要 6 个参数（含 Verify/ComputeChecksum） */
V1Switch(
    FissParser(),
    FissVerifyChecksum(),
    FissIngress(),
    FissEgress(),
    FissComputeChecksum(),
    FissDeparser()
) main;
