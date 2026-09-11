#ifndef MADEIRA_JAILBREAK_SUPPORT_H
#define MADEIRA_JAILBREAK_SUPPORT_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// The memory-limit call is attempted on every physical-device launch and
// returns false with EPERM when the process lacks jailbreak authorization.
// On a jailbroken device with tweak injection/fakesigning enabled these calls
// use the jailbreak's process hooks plus the iOS memorystatus API to prepare
// Madeira for FEX.
bool madeira_jb_is_jailbroken(void);
bool madeira_jb_is_debugged(void);
bool madeira_jb_jit_available(void);
bool madeira_jb_enable_jit(void);
bool madeira_jb_increase_memory_limit(void);
bool madeira_jb_initialize(void);

#ifdef __cplusplus
}
#endif

#endif // MADEIRA_JAILBREAK_SUPPORT_H
