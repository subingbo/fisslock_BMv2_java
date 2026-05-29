
#ifndef _SWITCH_BFRT_H
#define _SWITCH_BFRT_H

/*
 * ============================================================================
 * FissLock Tofino 控制面 — BFRT 符号与集群声明
 * ============================================================================
 *
 * BFRT（Barefoot Runtime）是控制面访问 P4 表/寄存器的 API。
 * 字符串须与编译后的 P4 程序名、表名一致（见 switch/p4/ingress.p4）。
 *
 * driver_init() 在 bfrt.c 中实现：灌 eth_fallback、创建组播组。
 * 锁寄存器多数由数据面 const 表自包含，控制面注释掉了 lock 数组编程。
 * ============================================================================
 */

/********************************************************* 
 * P4 程序中的符号字面量（与 Tofino 编译产物一致）
 *********************************************************/

#define P4_PROGRAM_NAME         "fisslock_decider"
#define P4_INGRESS_NAME         "IngressPipe"
#define P4_HEADERS_NAME         "hdr"

#define P4_TABLE(name)          P4_INGRESS_NAME "." name
#define P4_ACTION(name)         P4_INGRESS_NAME "." name
#define P4_REGISTER_DATA(name)  P4_INGRESS_NAME "." name ".f1"

/********************************************************* 
 * 集群机器表（数据来自 cluster.h）
 *********************************************************/

typedef struct {
  char* hostname;
  uint32_t ip_addr;
  uint64_t mac_addr;
  uint32_t port;
} machine_info;

static const machine_info connected_machines[] = {
#include "cluster.h"
};

#define MACHINE_NUM (sizeof(connected_machines) / sizeof(machine_info))
#define MID(i) ((i) + 1)   /* 组播组 ID 与 host 编号偏移 */

void driver_init();

// void lock_arr_add(lid_t lock, uint64_t data);
// void lock_arr_mod(lid_t lock, uint64_t data);
// void lock_arr_sync();

#endif
