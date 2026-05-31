# FissLock 文档

实验与学习笔记集中在本目录。

## 推荐阅读顺序

1. **[OPERATIONS_MANUAL_zh.md](./OPERATIONS_MANUAL_zh.md)** — **操作手册**（含 **§0 零基础**：三窗口、命令白话、抢锁 `PASS` 验收）  
2. [ARCHITECTURE_AND_RUNBOOK_zh.md](./ARCHITECTURE_AND_RUNBOOK_zh.md) — 总览：**为何需要 Sidecar**（§2.1–2.5）、进程、与 `lib` 差异  
3. [BMV2_UBUNTU_VALIDATION_zh.md](./BMV2_UBUNTU_VALIDATION_zh.md) — BMv2 三条数据面验证（Python / 组播 / thrift）  
4. [JAVA_INTEGRATION_zh.md](./JAVA_INTEGRATION_zh.md) — Java 接入阶段（0.1 Sidecar → 0.2 lib → 1.0 Tofino）  
5. [LIB_BMV2_INTEGRATION_zh.md](./LIB_BMV2_INTEGRATION_zh.md) — **C++ `lib/lock.cc` + JNI**（`FISSLOCK_BACKEND=lib`、抢锁）  
6. [JAVA_VM_DEPLOY_zh.md](./JAVA_VM_DEPLOY_zh.md) — 部署要点（与操作手册 §3–5 互补）

## 外部参考

| 文档 | 说明 |
|------|------|
| [../switch/LEARNING_zh.md](../switch/LEARNING_zh.md) | 交换机与 P4 概念导读 |
| [../switch/p4_bmv2/DEPLOY_UBUNTU.md](../switch/p4_bmv2/DEPLOY_UBUNTU.md) | BMv2 安装与脚本 |
| [../switch/p4_bmv2/README.md](../switch/p4_bmv2/README.md) | BMv2 测试期望 |
| [../java/fisslock-java/README.md](../java/fisslock-java/README.md) | Java 工程构建 |
