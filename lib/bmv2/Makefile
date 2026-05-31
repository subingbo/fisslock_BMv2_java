# BMv2 + lib/lock.cc：不依赖 DPDK，用 libpcap 对接 veth-inject / build/pcap
FISSLOCK_ROOT := ../..
BMV2_DIR := .
INC := -I$(BMV2_DIR) -I$(FISSLOCK_ROOT)/include -I$(FISSLOCK_ROOT)/utils -I$(FISSLOCK_ROOT)/lib
CXXFLAGS := -std=c++17 -fPIC -O2 -g -DFISSLOCK_BMV2 $(INC)
CFLAGS := -fPIC -O2 -g -DFISSLOCK_BMV2 $(INC)

JAVA_HOME ?= /usr/lib/jvm/java-17-openjdk-amd64
JNI_CFLAGS := -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/linux

TARGET := libfisslock_bmv2.so

CXX_SRCS := \
	$(BMV2_DIR)/bmv2_net.cc \
	$(BMV2_DIR)/bmv2_mbuf.cc \
	$(BMV2_DIR)/bmv2_stubs.cc \
	$(BMV2_DIR)/fisslock_host_api.cc \
	$(BMV2_DIR)/fisslock_jni.cpp \
	$(FISSLOCK_ROOT)/lib/lock.cc

C_SRCS := \
	$(FISSLOCK_ROOT)/lib/post.c \
	$(BMV2_DIR)/bmv2_conf.c

CXX_OBJS := $(CXX_SRCS:.cc=.o)
CXX_OBJS := $(CXX_OBJS:.cpp=.o)
C_OBJS := $(C_SRCS:.c=.o)
OBJS := $(CXX_OBJS) $(C_OBJS)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) $(JNI_CFLAGS) -shared -Wl,-soname,$(TARGET) -o $@ $(OBJS) -lpcap -lpthread
	@echo "==> $(TARGET)"

$(BMV2_DIR)/%.o: $(BMV2_DIR)/%.cc
	$(CXX) $(CXXFLAGS) $(JNI_CFLAGS) -c -o $@ $<

$(BMV2_DIR)/%.o: $(BMV2_DIR)/%.cpp
	$(CXX) $(CXXFLAGS) $(JNI_CFLAGS) -c -o $@ $<

$(FISSLOCK_ROOT)/lib/lock.o: $(FISSLOCK_ROOT)/lib/lock.cc
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(FISSLOCK_ROOT)/lib/post.o: $(FISSLOCK_ROOT)/lib/post.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(BMV2_DIR)/bmv2_conf.o: $(BMV2_DIR)/bmv2_conf.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS)
