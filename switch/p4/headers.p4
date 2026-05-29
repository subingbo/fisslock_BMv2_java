/*
 * ============================================================================
 * FissLock Tofino — 包头定义、锁常量、全局 metadata/header 结构
 * ============================================================================
 * 新手导读：switch/LEARNING_zh.md 第 2 节（锁包语义）
 * 主机侧对应：lib/post.h
 * ============================================================================
 */

////////////////////////////////////////////////////////////////////
// TCP/IP stack headers（标准以太网 / IP / UDP，非锁业务专用）
// 

typedef bit<48>  mac_addr_t;
typedef bit<32>  ipv4_addr_t;
typedef bit<128> ipv6_addr_t;
typedef bit<16>  udp_port_t;

typedef bit<16> eth_type;
const eth_type TYPE_IPV4 = 0x0800;
const eth_type TYPE_IPV6 = 0x86dd;
const eth_type TYPE_ARP  = 0x0806;

typedef bit<8> ip_type;
const ip_type TYPE_ICMP = 1;
const ip_type TYPE_TCP  = 6;
const ip_type TYPE_UDP  = 17;

header ethernet_t {
	mac_addr_t dst_mac;
	mac_addr_t src_mac;
	eth_type   l3_proto;
}

header ipv4_t {
	bit<4>      version;
	bit<4>      ihl;
	bit<8>      diffserv;
	bit<16>     total_len;
	bit<16>     ident;
	bit<3>      flags;
	bit<13>     frag_offset;
	bit<8>      ttl;
	bit<8>      l4_proto;
	bit<16>     hdr_cksum;
	ipv4_addr_t src_ip;
	ipv4_addr_t dst_ip;
}

header ipv6_t {
	bit<4>      version;
	bit<8>      traffic_class;
	bit<20>     flow_table;
	bit<16>     payload_len;
	bit<8>      next_hdr;
	bit<8>      hop_limit;
	ipv6_addr_t src_ip;
	ipv6_addr_t dst_ip;
}

header udp_t {
	udp_port_t src_port;
	udp_port_t dst_port;
	bit<16>    len;
	bit<16>    checksum;
}

header arp_t {
	bit<16>     hw_type;
	bit<16>     proto_type;
	bit<8>      hw_addr_len;
	bit<8>      proto_addr_len;
	bit<16>     opcode;
	mac_addr_t  src_mac;
	ipv4_addr_t src_ip;
	mac_addr_t  dst_mac;
	ipv4_addr_t dst_ip;
}

////////////////////////////////////////////////////////////////////
// RoCE headers.
// 
// The RoCE protocol we use is RoCEv2. See the spec here:
// https://docs.nvidia.com/networking/display/WINOFv55053000/RoCEv2
// 

// RoCE OpCodes.
typedef bit<8>  roce_op;
const roce_op ROCE_WRITE_REQ = 10;
const roce_op ROCE_READ_REQ = 12;
const roce_op ROCE_READ_RES = 16;
const roce_op ROCE_WRITE_RES = 17;
const roce_op ROCE_UC_WRITE_REQ = 42;

// RoCE-related data types.
typedef bit<24> qp_t;       /* RDMA Queue Pair */
typedef bit<24> psn_t;      /* Packet Sequence Number */
typedef bit<24> msn_t;      /* Message Sequence Number */
typedef bit<32> key_t;      /* Key for Authentication */
typedef bit<64> mem_addr_t; /* Memory Address */

// RoCEv2 identifies RDMA packets using a specific UDP port
// specified in the UDP header -- 4791.
const udp_port_t UDP_PORT_ROCE = 4791;

// Base RoCE L4 header (BTH).
header roce_t {
	bit<8>  opcode;         /* RDMA Op */
	bit<4>  _unused;        /* includes SE, MigReq, PadCnt */
	bit<4>  trans_hdr_ver;  /* BTH version */
	bit<16> p_key;          /* Associated logical partition key */
	bit<8>  _reserved;
	qp_t    dest_qp;        /* Destination QP Number */
	bit<1>  ack_req;        /* Is ACK required for this packet? */
	bit<7>  __reserved;
	psn_t   psn;            /* Used to detect missing packets */
}

// Extend RoCE L4 headers.
// 
// Depending on the QP and the operation types, there will
// be different extended header formats.

// RETH: for RC QP Read/Write REQ
header roce_reth_t {
	mem_addr_t  vaddr;  /* Remote address to read/write */
	key_t       rkey;   /* Authorize remote memory access */
	bit<32>     length; /* Read/Write data size */
}

// DETH: for UD QP Send/Recv REQ
header roce_deth_t {
	key_t   qkey;       /* Authorize acccesses to the receive queue */
	bit<8>  _reserved;
	qp_t    src_qp;     /* Source QP Number */
}

// AETH: for Any QP ACK
header roce_aeth_t {
	bit<8> syndrome;    /* ACK or NACK? */
	msn_t  msn;         /* Message Sequence Number */
}

////////////////////////////////////////////////////////////////////
// FissLock 网内锁（INL）包头与常量
// 

// 锁 UDP 端口：发往 agent 用 SERVER，发往普通客户端用 CLIENT
const udp_port_t UDP_PORT_SERVER = 20001;
const udp_port_t UDP_PORT_CLIENT = 20002;
const udp_port_t UDP_PORT_MEMDIFF = 20003;

/* 锁消息类型（lock_hdr_t.type），与 lib/post.h POST_LOCK_* 一致 */
#define ACQUIRE           0x01  /* 客户端申请锁 */
#define GRANT_W_AGENT     0x02  /* 交换机授权，请求者成为 agent */
#define GRANT_WO_AGENT    0x03  /* 交换机授权，agent 在其它主机 */
#define RELEASE           0x04  /* 释放（共享锁） */
#define TRANSFER          0x05  /* 转移 agent */
#define FREE              0x06  /* 释放锁（独占结束） */

#define MEM_DIFF          0x07  /* 内存差异同步（非锁裂变主路径） */

typedef bit<32> lid_t;
typedef bit<8>  host_t;

// 每个 slice 2^19 把锁；id[31:19] 选 stage 0/1/2（见 ingress.p4）
#define SLICE_SIZE_POW2 19
#define SLICE_SIZE      (1 << SLICE_SIZE_POW2) 
#define SLICE_NUM       8

/*
 * lock_hdr_t — UDP payload 中的 FissLock 锁头（与 post.h lock_post_header 对应）
 * 处理流程中会被 ingress/egress 修改 type、agent、multicasted、granted 等字段
 */
header lock_hdr_t {
	bit<8>  type;           /* 见上方 ACQUIRE、GRANT_W_AGENT 等 #define */
	bit<1>  multicasted;    /* 1=将走组播，egress 按 egress_rid 改 type */
	bit<1>  granted;        /* 对 agent：表示共享锁已授权给某 client */
	bit<1>  transferred;    /* agent 是否由 TRANSFER 迁入 */
	bit<3>  reserved;       
	bit<1>  old_mode;       /* TRANSFER/FREE 时：变更前的 LOCK_SHARED/LOCK_EXCL */
	bit<1>  mode;           /* 本包请求的 shared(0) 或 excl(1) */
	lid_t   id;	            /* 锁 ID；高 3 位选 Counter/Lock 的 stage */
	host_t  machine_id;     /* 请求者或下一持有者 host_id */
	bit<32> task_id;
	host_t  agent;          /* 转发目标：当前锁 agent 的 host_id */
	bit<32> wq_size;        /* 等待队列大小（主机栈用，交换机多不解析队列体） */
	bit<8>  ncnt;           /* 通知计数，须与片上 notification_cnt 一致 */
}

/* 片上 lock_free 寄存器取值 */
#define LOCK_FREE     0
#define LOCK_ACQUIRED 1

/* 片上 lock_rw 寄存器取值（锁已被占用后的模式） */
#define LOCK_SHARED   0
#define LOCK_EXCL     1

////////////////////////////////////////////////////////////////////
// 流水线 metadata（不随包出交换机，Parser/Ingress 间传递）
// 
typedef bit<9> egress_spec_t;

struct metadata_t {
	// --- 锁处理临时变量（Ingress 主流程使用）---
	bit<16>        dest2;              /* 组播第二组：mcast_grp_b = dest2+128 */
	bit<1>         lock_free_mode;     /* acquire/release 读到的原空闲状态 */
	bit<1>         lock_rw_mode;       /* 当前 shared/excl */
	host_t         lock_agent;         /* 待写入 agent 寄存器 */
	lid_t          lock_index;         /* slice 内索引，高 bit 已清零 */
	bit<1>         agent_changed;      /* counter 比较是否通过 */
	bit<1>         lock_out_of_range;  /* lock id 超出本交换机支持范围 */

	// --- RoCE 路径（与锁并行存在，实验环境可能用到）---
	bit<1>   is_roce;
	psn_t    pkt_psn;
}

struct header_t {
	ethernet_t  ethernet;
	ipv4_t      ipv4;
	ipv6_t      ipv6;
	arp_t       arp;
	udp_t       udp;
	roce_t      roce;
	roce_reth_t roce_reth;
	roce_deth_t roce_deth;
	roce_aeth_t roce_aeth;
	lock_hdr_t  lock;
}