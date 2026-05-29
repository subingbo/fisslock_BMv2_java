/*
 * ============================================================================
 * FissLock — 通知计数器（Notification Counter）三份 stage 副本
 * ============================================================================
 * CounterTable_1/2/3 逻辑完全相同，仅寄存器实例不同；
 * ingress 根据 lock.id[31:19] 选择 0→1、1→2、2→3（百万锁分 stage）。
 *
 * 作用（LEARNING_zh.md 路径 2）：
 *   - ACQUIRE shared：notification_cnt++
 *   - TRANSFER/FREE 且原 shared：比较包内 ncnt，一致则 agent_changed=1 并清零
 * ============================================================================
 */

control CounterTable_1(
	inout header_t hdr,
	inout metadata_t ig_md) {

    Register<bit<8>, lid_t>(SLICE_SIZE, 0) notification_cnt_1;

    RegisterAction<bit<8>, lid_t, bit<8>>(notification_cnt_1) count_ncnt = {
        void apply(inout bit<8> value) {
            value = value + 1;
        }
    };

    RegisterAction<bit<8>, lid_t, bit<8>>(notification_cnt_1) reset_ncnt = {
        void apply(inout bit<8> value) {
            value = 0;
        }
    };

    /* 与 BMv2 cnt_cmp 相同：一致则清零计数并 flag=1，否则认为网中有在途旧包 */
    RegisterAction<bit<8>, lid_t, bit<1>>(notification_cnt_1) cmp_ncnt = {
        void apply(inout bit<8> value, out bit<1> flag) {
            if (value == hdr.lock.ncnt) {
                value = 0;
                flag = 1;
            } else {
                flag = 0;
            }
        }
    };


    action get_notification_cnt() {
        ig_md.agent_changed = cmp_ncnt.execute(ig_md.lock_index);
    }

    action new_notification() {
        count_ncnt.execute(ig_md.lock_index);
    }

    action reset_notification_cnt() {
        reset_ncnt.execute(ig_md.lock_index);
    }

    action nop() {}

    table counter_table_1 {
        key = {
            hdr.lock.type: exact;
            hdr.lock.mode: exact;
            hdr.lock.old_mode: exact;
        }

        actions = {
            get_notification_cnt;
            reset_notification_cnt;
            new_notification;
            nop;
        }
        
        const entries = {
            // Type Mode Old-mode
            (ACQUIRE, LOCK_SHARED, 0): new_notification();
            (ACQUIRE, LOCK_SHARED, 1): new_notification();

            (TRANSFER, LOCK_SHARED, LOCK_SHARED): get_notification_cnt();
            (TRANSFER, LOCK_SHARED, LOCK_EXCL): reset_notification_cnt();
            (TRANSFER, LOCK_EXCL, LOCK_SHARED): get_notification_cnt();
            (TRANSFER, LOCK_EXCL, LOCK_EXCL): reset_notification_cnt();

            (FREE, LOCK_SHARED, LOCK_SHARED): get_notification_cnt();
            (FREE, LOCK_SHARED, LOCK_EXCL): reset_notification_cnt();
            (FREE, LOCK_EXCL, LOCK_SHARED): get_notification_cnt();
            (FREE, LOCK_EXCL, LOCK_EXCL): reset_notification_cnt();
        }

        const default_action = nop;
        size = 16;
    }

    apply {
        counter_table_1.apply();
    }
}

/* CounterTable_2：服务 lock.id[31:19]==1 的 slice（表项与 _1 相同） */
control CounterTable_2(
	inout header_t hdr,
	inout metadata_t ig_md) {

    Register<bit<8>, lid_t>(SLICE_SIZE, 0) notification_cnt_2;

    RegisterAction<bit<8>, lid_t, bit<8>>(notification_cnt_2) count_ncnt = {
        void apply(inout bit<8> value) {
            value = value + 1;
        }
    };

    RegisterAction<bit<8>, lid_t, bit<8>>(notification_cnt_2) reset_ncnt = {
        void apply(inout bit<8> value) {
            value = 0;
        }
    };

    RegisterAction<bit<8>, lid_t, bit<1>>(notification_cnt_2) cmp_ncnt = {
        void apply(inout bit<8> value, out bit<1> flag) {
            if (value == hdr.lock.ncnt) {
                value = 0;
                flag = 1;
            } else {
                flag = 0;
            }
        }
    };


    action get_notification_cnt() {
        ig_md.agent_changed = cmp_ncnt.execute(ig_md.lock_index);
    }

    action new_notification() {
        count_ncnt.execute(ig_md.lock_index);
    }

    action reset_notification_cnt() {
        reset_ncnt.execute(ig_md.lock_index);
    }

    action nop() {}

    table counter_table_2 {
        key = {
            hdr.lock.type: exact;
            hdr.lock.mode: exact;
            hdr.lock.old_mode: exact;
        }

        actions = {
            get_notification_cnt;
            reset_notification_cnt;
            new_notification;
            nop;
        }
        
        const entries = {
            // Type Mode Old-mode
            (ACQUIRE, LOCK_SHARED, 0): new_notification();
            (ACQUIRE, LOCK_SHARED, 1): new_notification();

            (TRANSFER, LOCK_SHARED, LOCK_SHARED): get_notification_cnt();
            (TRANSFER, LOCK_SHARED, LOCK_EXCL): reset_notification_cnt();
            (TRANSFER, LOCK_EXCL, LOCK_SHARED): get_notification_cnt();
            (TRANSFER, LOCK_EXCL, LOCK_EXCL): reset_notification_cnt();

            (FREE, LOCK_SHARED, LOCK_SHARED): get_notification_cnt();
            (FREE, LOCK_SHARED, LOCK_EXCL): reset_notification_cnt();
            (FREE, LOCK_EXCL, LOCK_SHARED): get_notification_cnt();
            (FREE, LOCK_EXCL, LOCK_EXCL): reset_notification_cnt();
        }

        const default_action = nop;
        size = 16;
    }

    apply {
        counter_table_2.apply();
    }
}

/* CounterTable_3：服务 lock.id[31:19]==2 的 slice */
control CounterTable_3(
	inout header_t hdr,
	inout metadata_t ig_md) {

    Register<bit<8>, lid_t>(SLICE_SIZE, 0) notification_cnt_3;

    RegisterAction<bit<8>, lid_t, bit<8>>(notification_cnt_3) count_ncnt = {
        void apply(inout bit<8> value) {
            value = value + 1;
        }
    };

    RegisterAction<bit<8>, lid_t, bit<8>>(notification_cnt_3) reset_ncnt = {
        void apply(inout bit<8> value) {
            value = 0;
        }
    };

    RegisterAction<bit<8>, lid_t, bit<1>>(notification_cnt_3) cmp_ncnt = {
        void apply(inout bit<8> value, out bit<1> flag) {
            if (value == hdr.lock.ncnt) {
                value = 0;
                flag = 1;
            } else {
                flag = 0;
            }
        }
    };


    action get_notification_cnt() {
        ig_md.agent_changed = cmp_ncnt.execute(ig_md.lock_index);
    }

    action new_notification() {
        count_ncnt.execute(ig_md.lock_index);
    }

    action reset_notification_cnt() {
        reset_ncnt.execute(ig_md.lock_index);
    }

    action nop() {}

    table counter_table_3 {
        key = {
            hdr.lock.type: exact;
            hdr.lock.mode: exact;
            hdr.lock.old_mode: exact;
        }

        actions = {
            get_notification_cnt;
            reset_notification_cnt;
            new_notification;
            nop;
        }
        
        const entries = {
            // Type Mode Old-mode
            (ACQUIRE, LOCK_SHARED, 0): new_notification();
            (ACQUIRE, LOCK_SHARED, 1): new_notification();

            (TRANSFER, LOCK_SHARED, LOCK_SHARED): get_notification_cnt();
            (TRANSFER, LOCK_SHARED, LOCK_EXCL): reset_notification_cnt();
            (TRANSFER, LOCK_EXCL, LOCK_SHARED): get_notification_cnt();
            (TRANSFER, LOCK_EXCL, LOCK_EXCL): reset_notification_cnt();

            (FREE, LOCK_SHARED, LOCK_SHARED): get_notification_cnt();
            (FREE, LOCK_SHARED, LOCK_EXCL): reset_notification_cnt();
            (FREE, LOCK_EXCL, LOCK_SHARED): get_notification_cnt();
            (FREE, LOCK_EXCL, LOCK_EXCL): reset_notification_cnt();
        }

        const default_action = nop;
        size = 16;
    }

    apply {
        counter_table_3.apply();
    }
}

