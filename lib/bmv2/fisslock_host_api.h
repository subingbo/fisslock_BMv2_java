#ifndef FISSLOCK_HOST_API_H
#define FISSLOCK_HOST_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 初始化：host_id、注入网卡、pcap 目录；内部 lock_setup + 轮询线程 */
int fl_bmv2_init(int host_id, const char* inject_iface, const char* pcap_dir);

/** 注册 lock_id（BMv2 演示用 lock_local_init，无控制面 RPC） */
int fl_bmv2_register_lock(uint32_t lock_id);

/** 独占 try-acquire，timeout_ms 内等待 C++ lib 收 GRANT */
int fl_bmv2_try_acquire_excl(uint32_t lock_id, uint32_t task_id, int timeout_ms);

int fl_bmv2_release_excl(uint32_t lock_id, uint32_t task_id);

void fl_bmv2_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
