#include "bmv2_mbuf.h"
#include "net.h"

#include <arpa/inet.h>
#include <pcap.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

static dispatcher_f g_dispatchers[NUM_POST_TYPES];
static char g_iface[64] = "veth-inject";
static std::string g_pcap_dir;
static uint64_t g_pcap_bytes_before = 0;
/** 每个 pcap 已分发过的包个数，避免重扫全文件重复处理 GRANT/FREE。 */
static std::unordered_map<std::string, int> g_pcap_packets_done;
static uint8_t g_eth_template[14 + 20 + 8];

void register_packet_dispatcher(post_t t, dispatcher_f f) {
  if (t >= 0 && t < NUM_POST_TYPES) {
    g_dispatchers[t] = f;
  }
}

int packet_dispatch(post_t t, void* buf, uint32_t core) {
  if (t < 0 || t >= NUM_POST_TYPES || !g_dispatchers[t]) {
    return 0;
  }
  return g_dispatchers[t](buf, core);
}

extern "C" void init_header_template(void) {
  memset(g_eth_template, 0, sizeof(g_eth_template));
  /* eth */
  uint8_t dst[] = {0x00, 0x00, 0x00, 0x00, 0x01, 0x00};
  uint8_t src[] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x01};
  memcpy(g_eth_template, dst, 6);
  memcpy(g_eth_template + 6, src, 6);
  g_eth_template[12] = 0x08;
  g_eth_template[13] = 0x00;
  /* ipv4 10.0.0.1 -> 10.0.0.2 */
  uint8_t* ip = g_eth_template + 14;
  ip[0] = 0x45;
  ip[9] = 17; /* UDP */
  ip[12] = 10;
  ip[13] = 0;
  ip[14] = 0;
  ip[15] = 1;
  ip[16] = 10;
  ip[17] = 0;
  ip[18] = 0;
  ip[19] = 2;
  /* udp sport 30000 dport SERVER_POST_TYPE */
  uint8_t* udp = ip + 20;
  udp[0] = 0x75;
  udp[1] = 0x30;
  udp[2] = (SERVER_POST_TYPE >> 8) & 0xff;
  udp[3] = SERVER_POST_TYPE & 0xff;
}

static uint64_t total_pcap_bytes(void) {
  static const char* names[] = {"veth-switch_out.pcap", "veth-h1_out.pcap",
                                "veth-h2_out.pcap"};
  uint64_t sum = 0;
  for (const char* n : names) {
    std::string path = g_pcap_dir + "/" + n;
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) {
      continue;
    }
    fseek(f, 0, SEEK_END);
    sum += static_cast<uint64_t>(ftell(f));
    fclose(f);
  }
  return sum;
}

static uint32_t checksum_fold(uint32_t sum) {
  while (sum >> 16) {
    sum = (sum & 0xffff) + (sum >> 16);
  }
  return sum;
}

/** 与 test_paths.py 一致：BMv2 可能丢弃 IP/UDP 校验和为 0 的注入包。 */
static void fix_ipv4_udp_checksums(uint8_t* frame, size_t post_size) {
  uint8_t* ip = frame + 14;
  uint8_t* udp = ip + 20;
  size_t udp_len = 8 + post_size;

  ip[10] = 0;
  ip[11] = 0;
  uint32_t sum = 0;
  for (size_t i = 0; i < 20; i += 2) {
    sum += (static_cast<uint32_t>(ip[i]) << 8) | ip[i + 1];
  }
  uint16_t ip_csum = static_cast<uint16_t>(~checksum_fold(sum));
  ip[10] = static_cast<uint8_t>(ip_csum >> 8);
  ip[11] = static_cast<uint8_t>(ip_csum & 0xff);

  udp[6] = 0;
  udp[7] = 0;
  sum = 0;
  sum += (static_cast<uint32_t>(ip[12]) << 8) | ip[13];
  sum += (static_cast<uint32_t>(ip[14]) << 8) | ip[15];
  sum += (static_cast<uint32_t>(ip[16]) << 8) | ip[17];
  sum += (static_cast<uint32_t>(ip[18]) << 8) | ip[19];
  sum += 17; /* UDP */
  sum += static_cast<uint32_t>(udp_len);
  for (size_t i = 0; i < udp_len; i += 2) {
    if (i + 1 < udp_len) {
      sum += (static_cast<uint32_t>(udp[i]) << 8) | udp[i + 1];
    } else {
      sum += static_cast<uint32_t>(udp[i]) << 8;
    }
  }
  uint16_t udp_csum = static_cast<uint16_t>(~checksum_fold(sum));
  if (udp_csum == 0) {
    udp_csum = 0xffff;
  }
  udp[6] = static_cast<uint8_t>(udp_csum >> 8);
  udp[7] = static_cast<uint8_t>(udp_csum & 0xff);
}

int bmv2_net_configure(const char* inject_iface,
                                  const char* pcap_dir) {
  if (inject_iface && inject_iface[0]) {
    strncpy(g_iface, inject_iface, sizeof(g_iface) - 1);
  }
  if (pcap_dir && pcap_dir[0]) {
    g_pcap_dir = pcap_dir;
  }
  g_pcap_packets_done.clear();
  g_pcap_bytes_before = total_pcap_bytes();
  return 0;
}

static void build_frame_from_post(uint64_t buf_hdl, size_t post_size,
                                uint8_t* out, size_t* out_len) {
  auto* p = reinterpret_cast<struct Bmv2PacketBuf*>(buf_hdl);
  char* post = reinterpret_cast<char*>(p->storage + (14 + 20 + 8));
  size_t total = 14 + 20 + 8 + post_size;
  memcpy(out, g_eth_template, 14 + 20 + 8);
  memcpy(out + 14 + 20 + 8, post, post_size);
  /* ipv4 total length */
  uint16_t ip_len = htons(static_cast<uint16_t>(20 + 8 + post_size));
  memcpy(out + 14 + 2, &ip_len, 2);
  uint16_t udp_len = htons(static_cast<uint16_t>(8 + post_size));
  memcpy(out + 14 + 20 + 4, &udp_len, 2);
  fix_ipv4_udp_checksums(out, post_size);
  *out_len = total;
}

int net_send(host_id /*dest*/, uint64_t buf_hdl, size_t size) {
  char errbuf[PCAP_ERRBUF_SIZE];
  pcap_t* pd = pcap_open_live(g_iface, 65535, 0, 10, errbuf);
  if (!pd) {
    fprintf(stderr, "[bmv2_net] pcap_open_live %s: %s\n", g_iface, errbuf);
    return -1;
  }
  uint8_t frame[512];
  size_t flen = 0;
  build_frame_from_post(buf_hdl, size, frame, &flen);
  int rc = pcap_inject(pd, frame, static_cast<int>(flen));
  pcap_close(pd);
  bmv2_net_free_buf(buf_hdl);
  if (rc < 0) {
    fprintf(stderr, "[bmv2_net] inject failed\n");
    return -1;
  }
  return 0;
}

extern "C" int net_send_batch(host_id dest, uint64_t* buf_hdls, size_t size,
                              int n) {
  for (int i = 0; i < n; i++) {
    net_send(dest, buf_hdls[i], size);
  }
  return 0;
}

static void dispatch_udp_payload(const uint8_t* payload, size_t len) {
  if (len < 1) {
    return;
  }
  post_t t = static_cast<post_t>(payload[0] & 0xff);
  if (t <= 0 || t >= NUM_POST_TYPES) {
    return;
  }
  /* packet_dispatch 期望 buf 指向 post_header */
  std::vector<uint8_t> buf(len);
  memcpy(buf.data(), payload, len);
  packet_dispatch(t, buf.data(), net_lcore_id());
}

static void scan_pcap_file(const char* path) {
  char errbuf[PCAP_ERRBUF_SIZE];
  pcap_t* pd = pcap_open_offline(path, errbuf);
  if (!pd) {
    return;
  }
  std::string key(path);
  int skip = g_pcap_packets_done[key];
  int index = 0;
  const u_char* pkt;
  pcap_pkthdr* hdr;
  while (pcap_next_ex(pd, &hdr, &pkt) == 1) {
    if (index < skip) {
      index++;
      continue;
    }
    index++;
    if (hdr->caplen < 14 + 20 + 8 + 1) {
      continue;
    }
    const uint8_t* ip = pkt + 14;
    if ((ip[0] >> 4) != 4) {
      continue;
    }
    size_t ihl = (ip[0] & 0x0f) * 4;
    const uint8_t* udp = ip + ihl;
    if (hdr->caplen < 14 + ihl + 8 + 1) {
      continue;
    }
    uint16_t dport = (udp[2] << 8) | udp[3];
    if (dport != SERVER_POST_TYPE && dport != CLIENT_POST_TYPE) {
      continue;
    }
    const uint8_t* payload = udp + 8;
    size_t plen = hdr->caplen - (payload - pkt);
    dispatch_udp_payload(payload, plen);
  }
  g_pcap_packets_done[key] = index;
  pcap_close(pd);
}

int net_poll_packets(void) {
  if (g_pcap_dir.empty()) {
    return 0;
  }
  uint64_t now = total_pcap_bytes();
  if (now <= g_pcap_bytes_before) {
    return 0;
  }
  g_pcap_bytes_before = now;
  static const char* names[] = {"veth-switch_out.pcap", "veth-h1_out.pcap",
                                "veth-h2_out.pcap"};
  for (const char* n : names) {
    scan_pcap_file((g_pcap_dir + "/" + n).c_str());
  }
  return 1;
}
