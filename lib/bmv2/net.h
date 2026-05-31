#ifndef __FISSLOCK_NET_BMV2_H
#define __FISSLOCK_NET_BMV2_H

/**
 * BMv2 构建用 net 头：libpcap 注入 veth-inject，从 build/pcap 读回包。
 * 由 lib/net.h 在 -DFISSLOCK_BMV2 时 include。
 */

#include "bmv2_compat.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "types.h"
#include "post.h"
#include "conf.h"

#define SERVER_POST_TYPE 20001
#define CLIENT_POST_TYPE 20002

typedef int (*dispatcher_f)(void* buf, uint32_t core);

#define net_lcore_id() (1u)
#define net_memcpy(dst, src, n) memcpy((dst), (src), (n))

#define net_new_buf() bmv2_net_new_buf()
#define net_new_buf_bulk(bufs, n) bmv2_net_new_buf_bulk((bufs), (n))
#define net_get_sendbuf(buf_hdl) bmv2_net_get_sendbuf(buf_hdl)

#ifdef __cplusplus
extern "C" {
#endif

void register_packet_dispatcher(post_t t, dispatcher_f f);
int packet_dispatch(post_t t, void* buf, uint32_t core);
int net_send(host_id dest, uint64_t buf_hdl, size_t size);
int net_send_batch(host_id dest, uint64_t* buf_hdls, size_t size, int n);
int net_poll_packets(void);
void init_header_template(void);

uint64_t bmv2_net_new_buf(void);
void bmv2_net_new_buf_bulk(uint64_t* bufs, uint32_t n);
char* bmv2_net_get_sendbuf(uint64_t buf_hdl);
void bmv2_net_free_buf(uint64_t buf_hdl);

int bmv2_net_configure(const char* inject_iface, const char* pcap_dir);
int bmv2_env_setup(int host_id);

#ifdef __cplusplus
}
#endif

#endif
