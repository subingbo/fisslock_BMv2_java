#include "rpc.h"
#include "statistics.h"
#include "fault.h"

#include <stdint.h>

extern "C" void* rpc(rpc_op op, const char* msg, size_t sz, size_t* reply_sz) {
  (void)op;
  (void)msg;
  (void)sz;
  static lock_id lid = 1;
  if (reply_sz) {
    *reply_sz = sizeof(lid);
  }
  return &lid;
}

extern "C" int rpc_setup_cli(const char* server_addr) {
  (void)server_addr;
  return 0;
}

extern "C" void fault_detector_setup(void) {}
extern "C" int check_error(char caller, lock_id lock, task_id task) {
  (void)caller;
  (void)lock;
  (void)task;
  return 0;
}

#define STUB_TIMER(name) \
  extern "C" void timer_##name(lock_id lock, task_id task) { \
    (void)lock; \
    (void)task; \
  } \
  extern "C" void timer_since_burst_##name(lock_id lock, task_id task) { \
    (void)lock; \
    (void)task; \
  }

STUB_TIMER(acquire)
STUB_TIMER(acquire_sent)
STUB_TIMER(grant_begin)
STUB_TIMER(grant_w_agent)
STUB_TIMER(grant_wo_agent)
STUB_TIMER(grant_local)
STUB_TIMER(grant_tx)
STUB_TIMER(release)
STUB_TIMER(release_sent)
STUB_TIMER(release_local)
STUB_TIMER(schedule_start)
STUB_TIMER(schedule_end)
STUB_TIMER(handle_acquire_begin)
STUB_TIMER(handle_acquire_end)
STUB_TIMER(queue_start)
STUB_TIMER(queue_end)
STUB_TIMER(secondary_begin)
STUB_TIMER(secondary_end)
STUB_TIMER(switch_direct_grant)

extern "C" void delay(uint64_t nanosec) { (void)nanosec; }
extern "C" void add_txn_lock_map(uint32_t a, uint32_t b) { (void)a; (void)b; }
extern "C" void txn_thpt_record(uint32_t a, uint32_t b, uint64_t c, uint64_t d,
                              int64_t e) {
  (void)a;
  (void)b;
  (void)c;
  (void)d;
  (void)e;
}
extern "C" void dynamic_thpt_record(uint32_t a, int b, double c) {
  (void)a;
  (void)b;
  (void)c;
}
extern "C" void report_thpt(void) {}
extern "C" void set_burst_time(void) {}
extern "C" void timer_schedule_from_to(lock_id a, task_id b, task_id c) {
  (void)a;
  (void)b;
  (void)c;
}
extern "C" void timer_start(void) {}
extern "C" uint64_t timer_now(void) { return 0; }
extern "C" void timer_txn_begin(uint32_t a, uint32_t b) { (void)a; (void)b; }
extern "C" void timer_txn_end(uint32_t a) { (void)a; }
extern "C" void report_timer(void) {}

#define DEF_COUNTER(name) \
  extern "C" void count_##name(void) {} \
  extern "C" void multi_count_##name(int c) { (void)c; } \
  extern "C" void count_##name##_or_abort(uint64_t c) { (void)c; }

DEF_COUNTER(fwd_back)
DEF_COUNTER(grant)
DEF_COUNTER(grant_with_agent)
DEF_COUNTER(grant_wo_agent)
DEF_COUNTER(grant_local)
DEF_COUNTER(rx)
DEF_COUNTER(tx)
DEF_COUNTER(client_acquire)
DEF_COUNTER(client_acquire_local)
DEF_COUNTER(client_acquire_remote)
DEF_COUNTER(client_release)
DEF_COUNTER(client_release_local)
DEF_COUNTER(client_release_remote)
DEF_COUNTER(client_abort)
DEF_COUNTER(server_acquire)
DEF_COUNTER(server_grant)
DEF_COUNTER(server_release)
DEF_COUNTER(switch_direct_grant)
DEF_COUNTER(primary)
DEF_COUNTER(secondary)
DEF_COUNTER(primary_acquire)
DEF_COUNTER(primary_release)
DEF_COUNTER(primary_grant)
DEF_COUNTER(secondary_acquire)
DEF_COUNTER(secondary_push_back)
DEF_COUNTER(secondary_release)

extern "C" uint32_t get_tx_count_lcore(uint32_t lcore_id) {
  (void)lcore_id;
  return 0;
}
extern "C" void report_counters(void) {}
extern "C" void inc_lock_queue_size(void) {}
extern "C" void dec_lock_queue_size(void) {}
extern "C" void report_lock_queue_size(void) {}

#define DEF_PROF(name) \
  extern "C" void profile_##name##_start(void) {} \
  extern "C" uint64_t profile_##name##_end(void) { return 0; }

DEF_PROF(lock_lkey)
DEF_PROF(lock_acquire)
DEF_PROF(lock_mprotect)
DEF_PROF(unlock_release)
DEF_PROF(unlock_mprotect)
DEF_PROF(mprotect)
extern "C" void report_profiler(void) {}
