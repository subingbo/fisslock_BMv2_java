/*
 * FissLock 实验集群 — 各主机在交换机上的连接信息
 *
 * 每行一条 machine_info（由 bfrt.h 的 connected_machines[] include）：
 *   { "主机名", IP地址(十六进制), MAC地址(十六进制), Tofino端口号 }
 *
 * 控制面 bfrt.c::driver_init() 用 MAC→port 填充 eth_fallback 表，
 * 用 MID(i) 创建组播组（agent 通知 / grant 回复）。
 *
 * 修改实验拓扑时编辑本文件后重新编译 control 程序。
 * 详见 switch/LEARNING_zh.md 第 4.2 节
 */
{"pro0-1", 0x0a000204, 0x1070fd0de230, 24},
{"pro1-1", 0x0a000201, 0x08c0ebfd52c4, 16},
{"pro2-1", 0x0a000202, 0x08c0ebfe8c50, 4},
{"pro3-1", 0x0a000203, 0x1070fd0de448, 12},
{"pro0-2", 0x0a000205, 0x08c0ebde0156, 56},
{"pro1-2", 0x0a000206, 0x08c0ebdcb30a, 48},
{"pro2-2", 0x0a000207, 0x08c0ebde011a, 40},
{"pro3-2", 0x0a000208, 0x08c0ebdca15a, 32},
