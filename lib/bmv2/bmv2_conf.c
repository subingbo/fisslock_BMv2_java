#include <stdlib.h>
#include <string.h>

#include "conf.h"
#include "net.h"

configurations conf;

extern int bmv2_net_configure(const char* inject_iface, const char* pcap_dir);

int bmv2_env_setup(int host_id) {
  memset(&conf, 0, sizeof(conf));
  conf.tx_core_num = 1;
  conf.rx_core_num = 1;
  conf.max_lock_num = 1024;
  conf.localhost_id = (host_id > 0 && host_id < 256) ? (host_id) : 1;
  return 0;
}

int env_setup(int argc, char* argv[], int tx_num, int rx_num) {
  (void)argc;
  (void)argv;
  conf.tx_core_num = tx_num;
  conf.rx_core_num = rx_num;
  if (conf.max_lock_num == 0) {
    conf.max_lock_num = 1024;
  }
  if (conf.localhost_id == 0) {
    conf.localhost_id = 1;
  }
  return 0;
}
