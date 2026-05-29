#!/bin/bash
# ============================================================================
# 编译 FissLock Tofino P4 程序（需已设置 SDE、SDE_INSTALL 环境变量）
# ============================================================================
# 用法（在仓库根目录）：
#   ./switch/configure_p4.sh fisslock_decider switch/p4/switch.p4
# 参数：$1=P4_NAME（与 bfrt.h P4_PROGRAM_NAME 一致） $2=P4 主文件路径
# 架构：P4_16 + TNA（Intel Tofino）
# ============================================================================

$SDE/pkgsrc/p4-build/configure \
    --with-tofino \
    --with-p4c=bf-p4c \
    --prefix=$SDE_INSTALL \
    --bindir=$SDE_INSTALL/bin \
    P4_NAME=$1 \
    P4_PATH=$2 \
    P4_VERSION=p4-16 \
    P4_ARCHITECTURE=tna \
    LDFLAGS="-L$SDE_INSTALL/lib"
