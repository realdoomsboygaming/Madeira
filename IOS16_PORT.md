# Madeira iOS 16 port

This document records the iOS 16 contract used by the native app, FEX, and
the active Wine iOS virtual-memory implementation. It is deliberately separate
from the iOS 26 BRK/TXM experiments in `ARCHITECTURE_ANALYSIS.md`.

## Runtime contract

* The app minimum deployment target and every native build helper are 16.0.
* iOS 16 does not use `pthread_jit_write_protect_np`,
  `pthread_jit_write_with_callback_np`, or the iOS 26 BRK/TXM protocol. The
  callback APIs are newer than iOS 16; the iOS 26 protocol is selected only
  after a runtime OS-version check.
* JIT execution still requires a debugger-enabled process (`CS_DEBUGGED`). On
  iOS 16 the app therefore expects an external development debugger to attach;
  the StikDebug URL automation is advertised only on systems where that helper
  exists.

## Memory model

`app/Madeira/JITAllocator.c` is the single native allocator contract:

1. Create anonymous writable storage.
2. While `CS_DEBUGGED` is set, make its maximum protection executable so the
   kernel can establish an executable alias.
3. Create a shared `vm_remap` alias.
4. Keep current protections disjoint: the RW alias is writable/non-executable
   and the RX alias is executable/non-writable.
5. Emit through RW, publish with a release fence, and invalidate the RX
   instruction cache before execution.

The allocator reports every Mach failure with the operation, `kern_return_t`,
and `mach_error_string()`. It does not require `VM_LEDGER_FLAG_NO_FOOTPRINT`;
that private Jetsam experiment remains an optional diagnostic and failure is
non-fatal. A pool that cannot be created fails before Wine starts instead of
silently returning ordinary non-executable memory.

FEX's executable allocation wrappers request RX rather than RWX on iOS. Its
`DualMap::WriteOffset` redirects code generation and runtime patching to the RW
alias. Wine's active `build/ntdll-unix/virtual_ios.c` accepts the resulting
`PAGE_EXECUTE_READ` EC-code request and carves it from the same RX/RW pool.

## VA and memory pressure

The app declares and checks the increased-memory and extended-virtual-address
entitlements. Entitlements are still provisioning-dependent; declaring them is
not proof that a signed app received them. The UI reports the runtime values.

Pool geometry is passed to Wine through `WINE_IOS_JIT_RX`,
`WINE_IOS_JIT_RW`, and `WINE_IOS_JIT_SIZE`. Wine validates non-zero,
page-aligned, distinct aliases before publishing them to its signal and
allocation paths. The pool remains demand-committed and normal phys_footprint
accounting is the safe fallback when private ledger ownership is rejected.

The old high-VA pinning and fixed 64G/512G placement guesses are not part of
the iOS 16 allocator. Any game-specific VA layout must be added as a measured,
device-specific policy after observing the actual iOS 16 map.

## Validation checklist

On an iOS 16 device, attach the external debugger before pressing the JIT test
or starting Wine. The in-app mapping test must log:

* `CS_DEBUGGED: SET`;
* `backend=ios16-legacy-dualmap`;
* different RW/RX addresses with coherent readback;
* RW current protection without execute and RX current protection without
  write; and
* successful `mov x0, #42; ret` execution plus the add-function test.

If any allocation or protection call fails, the exact Mach error is logged and
Wine launch is refused. The CI target builds with the iOS 16 deployment flag;
device execution and final Mach-O loading still require an Apple toolchain and
hardware (or a matching simulator runtime).

## References

* [Apple: Porting just-in-time compilers to Apple silicon](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)
* [Apple libpthread header history](https://github.com/apple-oss-distributions/libpthread/blob/libpthread-498.1.1/include/pthread.h)
* [Jailed Just-in-Time Compilation on iOS](https://saagarjha.com/blog/2020/05/20/jailed-just-in-time-compilation-on-ios/)
* [Apple `mach_make_memory_entry_64` reference](https://developer.apple.com/documentation/kernel/1402196-mach_make_memory_entry_64)
* [Darwin/XNU 8792 VM flags](https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-8792.61.2/osfmk/mach/vm_statistics.h)
* [StikJIT integration notes](https://github.com/StephenMcVicker/StikJIT/blob/main/INTEGRATION.md)
