#ifndef FISSLOCK_BMV2_MBUF_H
#define FISSLOCK_BMV2_MBUF_H

#include <stdint.h>

struct Bmv2PacketBuf {
  uint8_t storage[2048];
};

#ifdef __cplusplus
extern "C" {
#endif

void bmv2_net_free_buf(uint64_t buf_hdl);

#ifdef __cplusplus
}
#endif

#endif
