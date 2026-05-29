
/*
 * ============================================================================
 * FissLock Tofino — Ingress 流水线（锁逻辑主控）
 * ============================================================================
 * 包含：#include lock.p4, counter.p4
 *
 * 片上状态（每把锁）：
 *   lock_free_mode_array — 0=FREE 1=ACQUIRED（RegisterAction acquire/release）
 *   lock_rw_mode_array   — SHARED/EXCL（set_shared/set_excl/get_mode）
 *   lock_agent_array_*   — 在 lock.p4 各 stage
 *   notification_cnt_*   — 在 counter.p4
 *
 * 非锁以太网：eth_fallback 按目的 MAC 单播（控制面 bfrt.c 灌表）
 *
 * apply 主流程见文件末尾编号注释；对照 BMv2：p4_bmv2/fisslock_bmv2.p4 Ingress
 * 新手导读：switch/LEARNING_zh.md
 * ============================================================================
 */

#include "lock.p4"
#include "counter.p4"

control IngressPipe(
	inout header_t hdr,
    inout metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md) {

    /* 全锁表：SLICE_SIZE * SLICE_NUM 项；Tofino RegisterAction 原子读改写 */
    Register<bit<1>, lid_t>(SLICE_SIZE * SLICE_NUM, 0) lock_free_mode_array;
    Register<bit<1>, lid_t>(SLICE_SIZE * SLICE_NUM, 0) lock_rw_mode_array;

    RegisterAction<bit<1>, lid_t, bit<1>>(lock_free_mode_array) acquire = {
        void apply(inout bit<1> value, out bit<1> state) {
            state = value;           // 读出 acquire 前的状态 → ig_md.lock_free_mode
            value = LOCK_ACQUIRED;
        }
    };

    RegisterAction<bit<1>, lid_t, bit<1>>(lock_free_mode_array) release = {
        void apply(inout bit<1> value, out bit<1> state) {
            state = value;
            value = LOCK_FREE;
        }
    };

    RegisterAction<bit<1>, lid_t, bit<1>>(lock_rw_mode_array) set_shared = {
        void apply(inout bit<1> value, out bit<1> state) {
            state = value;
            value = LOCK_SHARED;
        }
    };

    RegisterAction<bit<1>, lid_t, bit<1>>(lock_rw_mode_array) set_excl = {
        void apply(inout bit<1> value, out bit<1> state) {
            state = value;
            value = LOCK_EXCL;
        }
    };

    RegisterAction<bit<1>, lid_t, bit<1>>(lock_rw_mode_array) get_mode = {
        void apply(inout bit<1> value, out bit<1> state) {
            state = value;
        }
    };

    action drop() {
        ig_intr_dprsr_md.drop_ctl = 0x1;
    }

    action nop() {}

	action eth_forward(PortId_t port) {
        ig_intr_tm_md.ucast_egress_port = port;
        ig_intr_dprsr_md.drop_ctl = 0x0;
	}

    action forward_to_host(PortId_t port) {
        ig_intr_tm_md.ucast_egress_port = port;
        ig_intr_dprsr_md.drop_ctl = 0x0;
    }

    action lock_shared() {
        ig_md.lock_rw_mode = set_shared.execute(hdr.lock.id);
    }

    action lock_excl() {
        ig_md.lock_rw_mode = set_excl.execute(hdr.lock.id);
    }

    action lock_mode_get() {
        ig_md.lock_rw_mode = get_mode.execute(hdr.lock.id);
    }

    action acquire_lock() {
        ig_md.lock_free_mode = acquire.execute(hdr.lock.id);
    }

    action release_lock() {
        ig_md.lock_free_mode = release.execute(hdr.lock.id);
    }

    /* 非锁包：按以太网目的 MAC 转发（表项由控制面 driver_init 填充） */
    table eth_fallback {
        key = {
            hdr.ethernet.dst_mac: exact;
        }

        actions = {
            eth_forward;
            @defaultonly drop;
        }

        const default_action = drop;
        size = 32;
    }

    /* 读写模式：ACQUIRE 设 mode；已占用则 get；TRANSFER/FREE 更新 mode */
    table rw_table {
        key = {
            hdr.lock.type: exact;
            ig_md.lock_free_mode: exact;
            hdr.lock.mode: exact;
        }

        actions = {
            lock_shared;
            lock_excl;
            lock_mode_get;
            nop;
        }

        const entries = {
            (TRANSFER, LOCK_ACQUIRED, LOCK_SHARED): lock_shared();
            (TRANSFER, LOCK_ACQUIRED, LOCK_EXCL): lock_excl();
            (FREE, LOCK_ACQUIRED, LOCK_SHARED): lock_shared();
            (FREE, LOCK_ACQUIRED, LOCK_EXCL): lock_excl();

            (ACQUIRE, LOCK_FREE, LOCK_SHARED): lock_shared();
            (ACQUIRE, LOCK_FREE, LOCK_EXCL): lock_excl();
            (ACQUIRE, LOCK_ACQUIRED, LOCK_SHARED): lock_mode_get();
            (ACQUIRE, LOCK_ACQUIRED, LOCK_EXCL): lock_mode_get();
        }

        const default_action = nop;
        size = 16;
    }

    table acquire_table {
        actions = {
            acquire_lock;
        }
        const default_action = acquire_lock;
        size = 1;
    }

    table release_table {
        actions = {
            release_lock;
        }
        const default_action = release_lock;
        size = 1;
    }

    apply {

        if (hdr.lock.isValid()) {

            // ① 初始化本包 metadata / 锁头标志位
            ig_md.dest2 = 0;
            ig_md.agent_changed = 0;
            ig_md.lock_out_of_range = 0;
            hdr.lock.multicasted = 0;
            hdr.lock.granted = 0;

            // ② 按 lock id 选 stage：单 stage 装不下百万级寄存器，拆成 3 段
            //    lock_index = id 低 19 位，高 3 位选 CounterTable / LockOperation 实例
            ig_md.lock_index = hdr.lock.id;
            ig_md.lock_index[31:SLICE_SIZE_POW2] = 0;

            if (hdr.lock.id[31:SLICE_SIZE_POW2] == 0) {
                CounterTable_1.apply(hdr, ig_md);
            } else if (hdr.lock.id[31:SLICE_SIZE_POW2] == 1) {
                CounterTable_2.apply(hdr, ig_md);
            } else if (hdr.lock.id[31:SLICE_SIZE_POW2] == 2) {
                CounterTable_3.apply(hdr, ig_md);
            } else {
                ig_md.lock_out_of_range = 1;
            }

            // ③ 分支：超范围 / counter 不一致跳过状态机 / agent 转发包 / 正常锁处理
            if (ig_md.lock_out_of_range == 1) {
                // 超出本 switch 管理的 id：仅对 GRANT_WO_AGENT 改 client 端口
                if (hdr.lock.type == GRANT_WO_AGENT) {
                    hdr.udp.dst_port = UDP_PORT_CLIENT;
                }

            } else if ((hdr.lock.type == TRANSFER || hdr.lock.type == FREE) && 
                hdr.lock.old_mode == LOCK_SHARED && ig_md.agent_changed == 0) {

                // TRANSFER/FREE 但 ncnt 与片上计数不一致 → 网中仍有在途包
                // 不执行 acquire/rw/lock_op，保留 hdr.lock.agent 原样转发给 agent

            } else if (hdr.lock.type == GRANT_WO_AGENT) {
                // 来自 agent 的授权转发，交换机不再改状态，只设 agent 为 machine_id
                hdr.lock.agent = hdr.lock.machine_id;

            } else {

                // ④ 更新 free 状态（FREE 包走 release，其余 acquire）
                if (hdr.lock.type != FREE) {
                    acquire_table.apply();
                } else {
                    release_table.apply();
                }

                rw_table.apply();

                ig_md.lock_agent = hdr.lock.machine_id;

                // ⑤ 锁裂变状态机（与 BMv2 lock_op_table 同表项）
                if (hdr.lock.id[31:SLICE_SIZE_POW2] == 0) {
                    LockOperation_1.apply(hdr, ig_md);
                } else if (hdr.lock.id[31:SLICE_SIZE_POW2] == 1) {
                    LockOperation_2.apply(hdr, ig_md);
                } else {
                    LockOperation_3.apply(hdr, ig_md);
                }
            }

            // ⑥ 转发：同时设两组播 ID，由 TM 复制；agent=0 或 dest2=0 的组被保留为空组播→丢副本
            //    mcast_grp_a → agent 通知（rid=1）；mcast_grp_b → client 授权（rid=2，+128 偏移）
            ig_intr_tm_md.mcast_grp_a = (bit<16>)hdr.lock.agent;
            ig_intr_tm_md.mcast_grp_b = ig_md.dest2 + 16w128;

        } else if (hdr.ethernet.isValid()) {
            eth_fallback.apply();
		}
    }
}
