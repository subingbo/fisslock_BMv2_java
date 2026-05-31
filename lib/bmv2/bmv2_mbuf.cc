#include "bmv2_mbuf.h"
#include "net.h"

#include <cstdlib>
#include <cstring>

static constexpr size_t kHdrReserve = 14 + 20 + 8;

uint64_t bmv2_net_new_buf(void) {
  auto* p = new Bmv2PacketBuf();
  memset(p->storage, 0, sizeof(p->storage));
  return reinterpret_cast<uint64_t>(p);
}

extern "C" void bmv2_net_new_buf_bulk(uint64_t* bufs, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    bufs[i] = bmv2_net_new_buf();
  }
}

char* bmv2_net_get_sendbuf(uint64_t buf_hdl) {
  auto* p = reinterpret_cast<Bmv2PacketBuf*>(buf_hdl);
  return reinterpret_cast<char*>(p->storage + kHdrReserve);
}

void bmv2_net_free_buf(uint64_t buf_hdl) {
  delete reinterpret_cast<Bmv2PacketBuf*>(buf_hdl);
}
