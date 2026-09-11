// Jailbreak support for automatic JIT and the Jetsam memory limit.
//
// The JIT path follows the same iOS technique used by UTM: PT_TRACE_ME makes
// the process take the debugged code-signing path, while PT_SIGEXC and a
// process-owned exception port keep an unexpected software exception from
// being routed into an invalid debugger session. On jailbreaks that expose
// libjailbreak's process API, that API is tried first as well.
// The corresponding UTM implementation is Apache-2.0 licensed; this file is
// an independent, smaller integration for Madeira rather than a hard link to
// UTM's Objective-C service layer.

#include "JailbreakSupport.h"

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
#ifndef PT_TRACE_ME
#define PT_TRACE_ME 0
#endif
#ifndef PT_SIGEXC
#define PT_SIGEXC 12
#endif

// Private iOS API used by jailbreaks and by UTM's jailbreak support.
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES 7
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8
#define MADEIRA_MEMLIMIT_GIB 1024

typedef struct memorystatus_memlimit_properties {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                user_addr_t buffer, size_t buffersize);
extern boolean_t exc_server(mach_msg_header_t *, mach_msg_header_t *);

typedef int (*jb_set_process_debugged_fn)(pid_t pid, bool debugged);

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_jailbreak = -1;
static bool g_ptrace_attempted = false;
static bool g_exception_handler_installed = false;
static bool g_jit_armed = false;

static void jb_log(const char *message) {
    fprintf(stderr, "[Jailbreak] %s\n", message);
}

static bool path_or_image_says_jailbreak(const char *value) {
    if (!value) return false;
    return strstr(value, "systemhook") != NULL ||
           strstr(value, "ellekit") != NULL ||
           strstr(value, "libjailbreak") != NULL ||
           strstr(value, "Substitute") != NULL ||
           strstr(value, "libhooker") != NULL ||
           strstr(value, "/var/jb/") != NULL;
}

static bool has_jailbreak_image(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (path_or_image_says_jailbreak(_dyld_get_image_name(i))) return true;
    }
    return false;
}

static bool has_jailbreak_api(void) {
    // systemhook normally exports this through libjailbreak. Do not require
    // a hard link: a regular App Store/sideloaded build must still launch.
    return dlsym(RTLD_DEFAULT, "jbclient_platform_set_process_debugged") != NULL;
}

bool madeira_jb_is_jailbroken(void) {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    return false;
#else
    pthread_mutex_lock(&g_lock);
    if (g_jailbreak < 0) {
        // Rootless jailbreak paths are often hidden by the app sandbox, so
        // the injected image/API checks are the primary signal. The path
        // checks cover jailbreaks that expose their bootstrap to the app.
        bool detected = has_jailbreak_image() || has_jailbreak_api() ||
                        access("/var/jb", F_OK) == 0 ||
                        access("/var/LIB", F_OK) == 0;
        g_jailbreak = detected ? 1 : 0;
    }
    bool result = g_jailbreak != 0;
    pthread_mutex_unlock(&g_lock);
    return result;
#endif
}

bool madeira_jb_is_debugged(void) {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    return false;
#else
    uint32_t flags = 0;
    return csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0 &&
           (flags & CS_DEBUGGED) != 0;
#endif
}

bool madeira_jb_jit_available(void) {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    return false;
#else
    if (!madeira_jb_is_jailbroken()) return false;
    if (madeira_jb_is_debugged()) return true;
    pthread_mutex_lock(&g_lock);
    bool armed = g_jit_armed;
    pthread_mutex_unlock(&g_lock);
    return armed;
#endif
}

// exc_server dispatches to this conventional callback name, matching the
// generated Mach exception server interface used by UTM.
kern_return_t catch_exception_raise(
    mach_port_t exception_port,
    mach_port_t thread,
    mach_port_t task,
    exception_type_t exception,
    exception_data_t code,
    mach_msg_type_number_t code_count) {
    (void)exception_port;
    (void)thread;
    (void)task;
    (void)code_count;
    fprintf(stderr, "[Jailbreak] software exception %d (0x%x); refusing debugger continuation\n",
            exception, code ? code[0] : 0);
    return KERN_FAILURE;
}

static void *madeira_exception_server(void *argument) {
    mach_port_t port = *(mach_port_t *)argument;
    free(argument);
    mach_msg_server(exc_server, 2048, port, 0);
    return NULL;
}

static bool install_ptrace_safety_net(void) {
    if (g_exception_handler_installed) return true;

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (kr != KERN_SUCCESS) {
        jb_log("mach_port_allocate failed for the self-debug exception port");
        return false;
    }
    kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        mach_port_destroy(mach_task_self(), port);
        jb_log("mach_port_insert_right failed for the self-debug exception port");
        return false;
    }
    kr = task_set_exception_ports(mach_task_self(), EXC_MASK_SOFTWARE, port,
                                  EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    if (kr != KERN_SUCCESS) {
        mach_port_destroy(mach_task_self(), port);
        jb_log("task_set_exception_ports failed for the self-debug exception port");
        return false;
    }

    mach_port_t *argument = malloc(sizeof(*argument));
    if (!argument) return false;
    *argument = port;
    pthread_t thread;
    if (pthread_create(&thread, NULL, madeira_exception_server, argument) != 0) {
        free(argument);
        return false;
    }
    pthread_detach(thread);
    g_exception_handler_installed = true;
    return true;
}

bool madeira_jb_enable_jit(void) {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    return false;
#else
    if (!madeira_jb_is_jailbroken()) return false;
    if (madeira_jb_is_debugged()) return true;

    pthread_mutex_lock(&g_lock);
    if (madeira_jb_is_debugged()) {
        pthread_mutex_unlock(&g_lock);
        return true;
    }

    // Dopamine/ElleKit may expose the process API through the injected
    // systemhook. It is harmless when absent and avoids depending solely on
    // the kernel's self-trace behavior.
    jb_set_process_debugged_fn set_debugged =
        (jb_set_process_debugged_fn)dlsym(RTLD_DEFAULT,
                                          "jbclient_platform_set_process_debugged");
    if (set_debugged) {
        int result = set_debugged(getpid(), true);
        if (result == 0) {
            g_jit_armed = true;
            jb_log("jailbreak process API armed JIT");
            pthread_mutex_unlock(&g_lock);
            return true;
        }
    }

    if (!g_ptrace_attempted) {
        g_ptrace_attempted = true;
        errno = 0;
        int result = ptrace(PT_TRACE_ME, 0, NULL, 0);
        if (result < 0) {
            char message[160];
            snprintf(message, sizeof(message), "ptrace(PT_TRACE_ME) failed: %s", strerror(errno));
            jb_log(message);
            pthread_mutex_unlock(&g_lock);
            return false;
        }
        // UTM's iOS implementation uses PT_SIGEXC plus an exception port for
        // this self-trace, otherwise an unexpected fault can hang the task.
        ptrace(PT_SIGEXC, 0, NULL, 0);
        install_ptrace_safety_net();
        g_jit_armed = true;
        jb_log("self-debug JIT path armed");
    }

    bool enabled = madeira_jb_is_debugged() || g_jit_armed;
    pthread_mutex_unlock(&g_lock);
    return enabled;
#endif
}

bool madeira_jb_increase_memory_limit(void) {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    return false;
#else
    // 1 TiB is an upper bound, not an allocation. The kernel applies the
    // device's own limits and pressure policy. On a jailbroken build, success requires either
    // root-equivalent execution or an effective private memorystatus
    // entitlement. Do not gate this attempt on jailbreak heuristics: rootless
    // injection can be present without exposing a recognizable image/path.
    memorystatus_memlimit_properties_t properties = {0};
    properties.memlimit_active = 1024 * MADEIRA_MEMLIMIT_GIB;
    properties.memlimit_inactive = 1024 * MADEIRA_MEMLIMIT_GIB;
    errno = 0;
    int result = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                                       getpid(), 0,
                                       (user_addr_t)(uintptr_t)&properties,
                                       sizeof(properties));
    if (result != 0) {
        char message[160];
        snprintf(message, sizeof(message), "memorystatus memory-limit request failed: %s",
                 strerror(errno));
        jb_log(message);
        return false;
    }

    // A successful setter only proves that the kernel accepted the request.
    // Read it back so the log distinguishes an effective jailbreak build from
    // a build whose source plist merely mentioned the private entitlement.
    memorystatus_memlimit_properties_t applied = {0};
    errno = 0;
    int readback = memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                                         getpid(), 0,
                                         (user_addr_t)(uintptr_t)&applied,
                                         sizeof(applied));
    if (readback != 0) {
        char message[192];
        snprintf(message, sizeof(message),
                 "memory-limit request accepted but readback failed: %s",
                 strerror(errno));
        jb_log(message);
        return false;
    }

    char message[192];
    snprintf(message, sizeof(message),
             "jailbreak memory limit active=%d MB inactive=%d MB",
             applied.memlimit_active, applied.memlimit_inactive);
    jb_log(message);
    return true;
#endif
}

bool madeira_jb_initialize(void) {
    // Memory-limit authorization and JIT authorization are independent. The
    // memory request is attempted even when jailbreak detection is incomplete;
    // a normally signed process simply receives EPERM. JIT still stays behind
    // the jailbreak check because its self-debug path changes process state.
    bool memory = madeira_jb_increase_memory_limit();
    bool jit = madeira_jb_is_jailbroken() && madeira_jb_enable_jit();
    return jit || memory;
}
