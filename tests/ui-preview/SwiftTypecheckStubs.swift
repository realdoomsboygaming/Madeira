import Foundation
import SwiftUI
import UIKit

enum MadeiraTheme {
    static let background = Color.black
    static let panel = Color.gray.opacity(0.2)
    static let accent = Color.green
    static let muted = Color.gray
    static let warning = Color.orange
}

struct EntitlementStatus {
    let increasedMemory = false
    let automaticMemory = false
    let extendedVA = false
    let jailbroken = false
    let automaticJIT = false
    static func check() -> EntitlementStatus { EntitlementStatus() }
}

final class InputSettings {
    static let shared = InputSettings()
    var relative = false
    var sensRel = 2.0
    var sensAbs = 2.0
    private init() {}
}

final class TouchControlsModel {
    static let shared = TouchControlsModel()
    var visible = true
    private init() {}
}

enum StikJITHelper {
    static var usesJailbreakSupport = false
    static var usesLegacyJIT = true
    static var isAvailable = true
    static func enableJIT(completion: @escaping (Bool) -> Void) { completion(true) }
    static func allocatePool(poolSize: Int) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? { nil }
    static func detachDebugger() {}
}

final class MetalBackedView: UIView {
    static func setPresentationVisible(_ visible: Bool) {}
    static func toggleKeyboard() {}
}

struct MadeiraMetalView: View {
    init(onReady: @escaping () -> Void) {}
    var body: some View { Color.black }
}

struct JoystickKeyView: View {
    var body: some View { EmptyView() }
}

struct FPSOverlay: View {
    init(compact: Bool) {}
    var body: some View { EmptyView() }
}

final class LogStore: ObservableObject {
    static let shared = LogStore()
    struct LogEntry: Identifiable {
        enum Level: String { case info = "INFO", success = "OK", error = "ERR", debug = "DBG" }
        let id = UUID()
        var level: Level = .info
        var lastRaw = ""
        var lastTimestamp = Date()
        var count = 1
    }
    @Published var entries: [LogEntry] = []
    func clear() { entries.removeAll() }
}

func jit_install_trap_handler() {}
func jit_check_debugged() -> Bool { true }
func jit_test_execute() -> Int64 { 42 }
func madeira_jb_initialize() -> Bool { true }
func madeira_jb_is_jailbroken() -> Bool { false }
func madeira_jb_jit_available() -> Bool { false }
func madeira_jb_increase_memory_limit() -> Bool { false }
func wineserver_start(_ path: String) -> Int32 { 0 }
func wineserver_is_running() -> Int32 { 0 }
func wineserver_stop() {}
func wine_process_start(_ path: String) -> Int32 { 0 }
func wine_process_is_running() -> Int32 { 0 }
func winios_post_key(_ key: Int32, _ down: Int32) {}
func madeira_set_diag_enabled(_ enabled: Int32) {}
