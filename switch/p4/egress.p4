/*
 * ============================================================================
 * FissLock Tofino — Egress 流水线（组播副本差异化改包）
 * ============================================================================
 *
 * 当 ingress 将 hdr.lock.multicasted 置 1 并设置 mcast_grp 时，
 * 交换机会复制多份包；每份带有 egress_rid（replica id）。
 *
 * 与 BMv2 fisslock_bmv2.p4 中 Egress 控制块逻辑一致：
 *   rid == 2 → 发给 client：GRANT_WO_AGENT + UDP 20002
 *   rid == 1 → 发给 agent：ACQUIRE + granted + UDP 20001
 *
 * 详见 LEARNING_zh.md 第 3.3 节（共享锁组播授权）
 * ============================================================================
 */

control EgressPipe(
	inout header_t hdr,
  inout metadata_t meta,
  in egress_intrinsic_metadata_t eg_intr_md,
  in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
  inout egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md,
  inout egress_intrinsic_metadata_for_output_port_t eg_intr_oport_md) {

  apply {
    if (hdr.lock.multicasted == 1 && eg_intr_md.egress_rid == 2) {
      // 组播副本 → 新申请共享锁的 client
      hdr.lock.type = GRANT_WO_AGENT;
      hdr.udp.dst_port = UDP_PORT_CLIENT;
      hdr.lock.multicasted = 0;
    } else if (hdr.lock.multicasted == 1 && eg_intr_md.egress_rid == 1) {
      // 组播副本 → 当前锁 agent（通知其有人获共享授权）
      hdr.lock.type = ACQUIRE;
      hdr.udp.dst_port = UDP_PORT_SERVER;
      hdr.lock.multicasted = 0;
      hdr.lock.granted = 1;
    }
  }
}
