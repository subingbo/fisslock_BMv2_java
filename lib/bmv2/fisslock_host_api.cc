#include "fisslock_host_api.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>

#include "conf.h"
#include "lock.h"
#include "net.h"

using namespace std::chrono_literals;

static std::atomic<bool> g_poll_run{false};
static std::thread g_poll_thread;

static void poll_loop(void) {
  while (g_poll_run.load()) {
    net_poll_packets();
    std::this_thread::sleep_for(8ms);
  }
}

extern "C" int fl_bmv2_init(int host_id, const char* inject_iface,
                            const char* pcap_dir) {
  bmv2_env_setup(host_id);
  bmv2_net_configure(inject_iface, pcap_dir);
  init_header_template();
  lock_setup(FLAG_ENB_LOCAL_GRANT);
  g_poll_run.store(true);
  g_poll_thread = std::thread(poll_loop);
  fprintf(stderr,
          "[lib] fl_bmv2_init host=%d iface=%s pcap=%s (C++ lock.cc)\n",
          host_id, inject_iface ? inject_iface : "", pcap_dir ? pcap_dir : "");
  return 0;
}

extern "C" int fl_bmv2_register_lock(uint32_t lock_id) {
  lock_local_init(lock_id);
  return 0;
}

extern "C" int fl_bmv2_try_acquire_excl(uint32_t lock_id, uint32_t task_id,
                                        int timeout_ms) {
  lock_key key = lock_id;
  lock_req req = lock_acquire_async(key, task_id, LOCK_EXCL);
  if (req == 0) {
    return 1;
  }
  auto deadline = std::chrono::steady_clock::now() +
                  std::chrono::milliseconds(timeout_ms > 0 ? timeout_ms : 3000);
  while (std::chrono::steady_clock::now() < deadline) {
    if (lock_req_granted(req, lock_id, task_id)) {
      return 1;
    }
    std::this_thread::sleep_for(5ms);
  }
  /* 超时：尽量 FREE，避免交换机仍占用而后续 ACQUIRE 一直失败 */
  lock_release(lock_id, task_id, LOCK_EXCL);
  return 0;
}

extern "C" int fl_bmv2_release_excl(uint32_t lock_id, uint32_t task_id) {
  return lock_release(lock_id, task_id, LOCK_EXCL) == 0 ? 0 : -1;
}

extern "C" void fl_bmv2_shutdown(void) {
  g_poll_run.store(false);
  if (g_poll_thread.joinable()) {
    g_poll_thread.join();
  }
}
