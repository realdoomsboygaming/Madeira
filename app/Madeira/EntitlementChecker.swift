import Foundation
import Security

private typealias SecTaskRef = OpaquePointer

@_silgen_name("SecTaskCopyValueForEntitlement")
private func _SecTaskCopyValueForEntitlement(
    _ task: SecTaskRef,
    _ entitlement: NSString,
    _ error: NSErrorPointer
) -> CFTypeRef?

@_silgen_name("SecTaskCreateFromSelf")
private func _SecTaskCreateFromSelf(
    _ allocator: CFAllocator?
) -> SecTaskRef?

func checkAppEntitlement(_ ent: String) -> Bool {
    guard let task = _SecTaskCreateFromSelf(nil) else { return false }

    guard let value = _SecTaskCopyValueForEntitlement(task, ent as NSString, nil) else {
        return false
    }

    if let number = value as? NSNumber {
        return number.boolValue
    }

    return false
}

struct EntitlementStatus {
    let jitAllowed: Bool
    let increasedMemory: Bool
    let privateMemoryLimit: Bool
    let extendedVA: Bool
    let jailbroken: Bool
    let automaticJIT: Bool
    let automaticMemory: Bool

    static func check() -> EntitlementStatus {
        let jailbroken = madeira_jb_is_jailbroken()
        return EntitlementStatus(
            jitAllowed: checkAppEntitlement("com.apple.security.cs.allow-jit"),
            increasedMemory: checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit"),
            privateMemoryLimit: checkAppEntitlement("com.apple.private.memorystatus"),
            extendedVA: checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing"),
            jailbroken: jailbroken,
            automaticJIT: jailbroken && madeira_jb_jit_available(),
            // The private memorystatus call is only meaningful on the
            // jailbreak path. Do not probe it during normal signed startup;
            // some builds terminate the process before UIKit can report a
            // useful error when that private call is attempted.
            automaticMemory: jailbroken ? madeira_jb_increase_memory_limit() : false
        )
    }
}

/* Runtime check: is a debugger attached to this process (P_TRACED)?
 * This is the signal StikDebug JIT actually rides on — CS_DEBUGGED gets
 * set while traced, enabling JIT-region execution. The allow-jit
 * ENTITLEMENT is macOS-only and never granted on iOS, so the old badge
 * built on it was permanently ✗ no matter what StikDebug did. */
func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let ret = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard ret == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}
