#ifndef FISSLOCK_BMV2_COMPAT_H
#define FISSLOCK_BMV2_COMPAT_H

/* lock.cc 中沿用 DPDK 宏名，BMv2 构建不提供 dpdk.h */
#ifndef DPDK_TX_BURST_SIZE
#define DPDK_TX_BURST_SIZE 1024
#endif

#ifndef unlikely
#define unlikely(x) __builtin_expect(!!(x), 0)
#endif

#ifndef likely
#define likely(x) __builtin_expect(!!(x), 1)
#endif

#endif
