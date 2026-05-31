#include "fisslock_host_api.h"

#include <jni.h>
#include <cstring>

extern "C" JNIEXPORT jint JNICALL
Java_com_fisslock_sidecar_FisslockNative_nativeInit(JNIEnv* env, jclass,
                                                    jint hostId,
                                                    jstring iface,
                                                    jstring pcapDir) {
  const char* ifc = env->GetStringUTFChars(iface, nullptr);
  const char* pcap = env->GetStringUTFChars(pcapDir, nullptr);
  int rc = fl_bmv2_init(hostId, ifc, pcap);
  env->ReleaseStringUTFChars(iface, ifc);
  env->ReleaseStringUTFChars(pcapDir, pcap);
  return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_fisslock_sidecar_FisslockNative_nativeRegisterLock(JNIEnv*, jclass,
                                                            jint lockId) {
  return fl_bmv2_register_lock(static_cast<uint32_t>(lockId));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_fisslock_sidecar_FisslockNative_nativeTryAcquireExcl(
    JNIEnv*, jclass, jint lockId, jint taskId, jint timeoutMs) {
  return fl_bmv2_try_acquire_excl(static_cast<uint32_t>(lockId),
                                  static_cast<uint32_t>(taskId), timeoutMs)
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_fisslock_sidecar_FisslockNative_nativeReleaseExcl(JNIEnv*, jclass,
                                                           jint lockId,
                                                           jint taskId) {
  return fl_bmv2_release_excl(static_cast<uint32_t>(lockId),
                            static_cast<uint32_t>(taskId));
}

extern "C" JNIEXPORT void JNICALL
Java_com_fisslock_sidecar_FisslockNative_nativeShutdown(JNIEnv*, jclass) {
  fl_bmv2_shutdown();
}
