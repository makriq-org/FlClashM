#ifdef LIBCLASH
#include <jni.h>
#include "jni_helper.h"
#include "libclash.h"

// ---------------------------------------------------------------------------
// Cached Java method IDs
// ---------------------------------------------------------------------------

static jmethodID m_tun_interface_protect;
static jmethodID m_tun_interface_resolve_process;
static jmethodID m_invoke_interface_on_result;

// ---------------------------------------------------------------------------
// Native helpers registered with the Go runtime via registerCallbacks
// ---------------------------------------------------------------------------

static void release_jni_object_impl(void *obj) {
    if (obj == nullptr) return;
    ATTACH_JNI();
    if (env == nullptr) return;
    del_global(static_cast<jobject>(obj));
}

static void call_tun_interface_protect_impl(void *tun_interface, const int fd) {
    ATTACH_JNI();
    if (env == nullptr) return;
    env->CallVoidMethod(static_cast<jobject>(tun_interface),
                        m_tun_interface_protect,
                        fd);
}

static const char *
call_tun_interface_resolve_process_impl(void *tun_interface, int protocol,
                                        const char *source,
                                        const char *target,
                                        const int uid) {
    ATTACH_JNI();
    if (env == nullptr) return "";
    const auto jSource = new_string(source);
    const auto jTarget = new_string(target);
    const auto packageName = reinterpret_cast<jstring>(env->CallObjectMethod(
            static_cast<jobject>(tun_interface),
            m_tun_interface_resolve_process,
            protocol,
            jSource,
            jTarget,
            uid));
    if (jSource) env->DeleteLocalRef(jSource);
    if (jTarget) env->DeleteLocalRef(jTarget);
    const char *result = get_string(packageName);
    if (packageName) env->DeleteLocalRef(packageName);
    return result;
}

/**
 * Delivered for one-shot callbacks (invokeAction / quickStart). After invoking
 * onResult we drop the global ref — the Go side never releases these.
 */
static void invoke_callback_impl(void *callback, const char *data) {
    if (callback == nullptr) return;
    ATTACH_JNI();
    if (env == nullptr) return;
    const auto target = static_cast<jobject>(callback);
    const auto jdata = new_string(data ? data : "");
    env->CallVoidMethod(target, m_invoke_interface_on_result, jdata);
    env->DeleteLocalRef(jdata);
    jni_catch_exception(env);
    del_global(target);
}

/**
 * Delivered for the long-lived event listener. Does NOT release the global ref
 * — Go releases it via setEventListener(prev)/releaseObject when replaced.
 */
static void event_listener_impl(void *listener, const char *data) {
    if (listener == nullptr) return;
    ATTACH_JNI();
    if (env == nullptr) return;
    const auto target = static_cast<jobject>(listener);
    const auto jdata = new_string(data ? data : "");
    env->CallVoidMethod(target, m_invoke_interface_on_result, jdata);
    env->DeleteLocalRef(jdata);
    jni_catch_exception(env);
}

// ---------------------------------------------------------------------------
// JNI bindings — mapped 1:1 to Core.kt externals
// ---------------------------------------------------------------------------

extern "C"
JNIEXPORT jboolean JNICALL
Java_com_follow_clashx_core_Core_nativeStartTun(JNIEnv *env, jobject, const jint fd, jobject cb) {
    const auto interface = new_global(cb);
    const auto ok = startTUN(fd, interface);
    return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_stopTun(JNIEnv *) {
    stopTun();
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_invokeAction(JNIEnv *env, jobject, jstring data, jobject cb) {
    const auto interface = new_global(cb);
    scoped_string c_data = get_string(data);
    invokeAction(c_data, interface);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_quickStart(JNIEnv *env, jobject,
                                            jstring init, jstring params, jstring state,
                                            jobject cb) {
    const auto interface = new_global(cb);
    scoped_string c_init = get_string(init);
    scoped_string c_params = get_string(params);
    scoped_string c_state = get_string(state);
    quickStart(c_init, c_params, c_state, interface);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_setEventListener(JNIEnv *env, jobject, jobject cb) {
    if (cb == nullptr) {
        setEventListener(nullptr);
        return;
    }
    const auto interface = new_global(cb);
    setEventListener(interface);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_setState(JNIEnv *env, jobject, jstring s) {
    scoped_string c_s = get_string(s);
    setState(c_s);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_updateDns(JNIEnv *env, jobject, jstring s) {
    scoped_string c_s = get_string(s);
    updateDns(c_s);
}

// Helper macro for getters returning a Go-allocated char* that must be freed via freeCString.
#define RETURN_GO_STRING(expr)                                           \
    do {                                                                 \
        char *raw = (expr);                                              \
        if (raw == nullptr) return env->NewStringUTF("");                \
        jstring result = env->NewStringUTF(raw);                         \
        freeCString(raw);                                                \
        return result;                                                   \
    } while (0)

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clashx_core_Core_getTraffic(JNIEnv *env, jobject) {
    RETURN_GO_STRING(getTraffic());
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clashx_core_Core_getTotalTraffic(JNIEnv *env, jobject) {
    RETURN_GO_STRING(getTotalTraffic());
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clashx_core_Core_getRunTime(JNIEnv *env, jobject) {
    RETURN_GO_STRING(getRunTime());
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clashx_core_Core_getCurrentProfileName(JNIEnv *env, jobject) {
    RETURN_GO_STRING(getCurrentProfileName());
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clashx_core_Core_getAndroidVpnOptions(JNIEnv *env, jobject) {
    RETURN_GO_STRING(getAndroidVpnOptions());
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clashx_core_Core_getConfig(JNIEnv *env, jobject, jstring s) {
    scoped_string c_s = get_string(s);
    RETURN_GO_STRING(getConfig(c_s));
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_resetConnections(JNIEnv *, jobject) {
    resetConnections();
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_startListener(JNIEnv *, jobject) {
    startListener();
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clashx_core_Core_stopListener(JNIEnv *, jobject) {
    stopListener();
}

// ---------------------------------------------------------------------------
// JNI_OnLoad — wires Go callback slots and caches method IDs
// ---------------------------------------------------------------------------

extern "C"
JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    initialize_jni(vm, env);

    const auto c_tun_interface = find_class("com/follow/clashx/core/TunInterface");
    if (c_tun_interface == nullptr) return JNI_ERR;
    m_tun_interface_protect = find_method(c_tun_interface, "protect", "(I)V");
    m_tun_interface_resolve_process = find_method(
            c_tun_interface,
            "resolverProcess",
            "(ILjava/lang/String;Ljava/lang/String;I)Ljava/lang/String;");

    const auto c_invoke_interface = find_class("com/follow/clashx/core/InvokeInterface");
    if (c_invoke_interface == nullptr) return JNI_ERR;
    m_invoke_interface_on_result = find_method(
            c_invoke_interface,
            "onResult",
            "(Ljava/lang/String;)V");

    if (m_tun_interface_protect == nullptr || m_tun_interface_resolve_process == nullptr ||
        m_invoke_interface_on_result == nullptr) return JNI_ERR;

    registerCallbacks(&invoke_callback_impl,
                      &event_listener_impl,
                      &call_tun_interface_protect_impl,
                      &call_tun_interface_resolve_process_impl,
                      &release_jni_object_impl);

    return JNI_VERSION_1_6;
}
#endif
