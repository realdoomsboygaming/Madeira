import Foundation
import Combine

enum RuntimeState: Equatable {
    case idle
    case preparing
    case starting
    case running
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Runtime idle"
        case .preparing: return "Preparing runtime"
        case .starting: return "Starting Windows"
        case .running: return "Runtime active"
        case .stopped: return "Runtime stopped"
        case .failed(let message): return message
        }
    }
}

struct WineLaunchConfiguration: Equatable {
    let executable: String
    let arguments: String
    let environment: [String: String]
}

enum RuntimeServiceError: LocalizedError {
    case jitUnavailable
    case jitPoolFailed
    case bundledResourceMissing(String)
    case wineserverFailed(Int32)
    case wineFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .jitUnavailable:
            return "JIT is unavailable. Enable JIT in Settings before launching Windows software."
        case .jitPoolFailed:
            return "Madeira could not allocate the JIT memory pool. Close other apps and try again."
        case .bundledResourceMissing(let resource):
            return "Madeira is missing bundled runtime content: \(resource). Reinstall the IPA instead of launching this incomplete build."
        case .wineserverFailed(let code):
            return "The Wine server could not start (error \(code))."
        case .wineFailed(let code):
            return "Wine could not start (error \(code)). Open Diagnostics for details."
        }
    }
}

/// Owns the native Wine and wineserver lifecycle. SwiftUI only observes state;
/// it never assembles a Wine command line or mutates launch environment values.
final class RuntimeService: ObservableObject {
    @Published private(set) var state: RuntimeState = .idle

    private let jit: JITService
    private var hasStartedSession = false

    init(jit: JITService) {
        self.jit = jit
    }

    var isActive: Bool {
        if case .running = state { return true }
        return false
    }

    func start(configuration: WineLaunchConfiguration,
               poolSizeMB: Int,
               completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isActive, !hasStartedSession else {
            completion(.failure(RuntimeServiceError.wineFailed(-2)))
            return
        }

        hasStartedSession = true
        state = .preparing
        let launch = configuration
        let poolMB = min(max(poolSizeMB, 256), 1152)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.verifyBundledRuntime()
                let prefix = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("wine", isDirectory: true)
                guard self.jit.isAvailable else { throw RuntimeServiceError.jitUnavailable }
                guard self.jit.preparePool(megabytes: poolMB) else {
                    throw RuntimeServiceError.jitPoolFailed
                }

                self.applyEnvironment(launch)
                self.publish(.starting)

                let serverResult = wineserver_start(prefix.path)
                guard serverResult == 0 else {
                    throw RuntimeServiceError.wineserverFailed(serverResult)
                }

                // wineserver_start is asynchronous. Wait for its published
                // running bit instead of using a fixed launch delay.
                for _ in 0..<40 {
                    if wineserver_is_running() != 0 { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard wineserver_is_running() != 0 else {
                    throw RuntimeServiceError.wineserverFailed(-1)
                }

                let wineResult = wine_process_start(prefix.path)
                guard wineResult == 0 else {
                    throw RuntimeServiceError.wineFailed(wineResult)
                }

                self.publish(.running)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.publish(.failed(error.localizedDescription))
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Stops the server and marks the session inactive. The native Wine bridge
    /// owns its process thread and will finish its normal exit path after the
    /// server stop request; no unsafe thread cancellation is used here.
    func stop() {
        guard isActive || wineserver_is_running() != 0 else { return }
        wineserver_stop()
        publish(.stopped)
    }

    func refresh() {
        if wine_process_is_running() != 0 {
            publish(.running)
        } else if wineserver_is_running() == 0, isActive {
            publish(.stopped)
        }
    }

    private func applyEnvironment(_ launch: WineLaunchConfiguration) {
        setenv("MADEIRA_EXE", launch.executable, 1)
        if launch.arguments.isEmpty { unsetenv("MADEIRA_ARGS") }
        else { setenv("MADEIRA_ARGS", launch.arguments, 1) }

        let desktop = launch.environment["MADEIRA_DESKTOP"] == "1"
        if desktop {
            setenv("MADEIRA_DESKTOP", "1", 1)
        } else {
            unsetenv("MADEIRA_DESKTOP")
        }
        for (key, value) in launch.environment where key != "MADEIRA_DESKTOP" {
            setenv(key, value, 1)
        }
    }

    private func verifyBundledRuntime() throws {
        let fm = FileManager.default
        let bundleRoot = Bundle.main.bundleURL
        let requiredDirectories = [
            "aarch64-windows",
            "arm64ec-windows",
            "i386-windows",
            "x86_64-vcruntime",
            "nls"
        ]
        for name in requiredDirectories {
            let url = bundleRoot.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  (try? fm.contentsOfDirectory(atPath: url.path).isEmpty) == false else {
                throw RuntimeServiceError.bundledResourceMissing(name)
            }
        }

        guard Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil else {
            throw RuntimeServiceError.bundledResourceMissing("prefix-template.tar.gz")
        }
    }

    private func publish(_ newState: RuntimeState) {
        DispatchQueue.main.async { [weak self] in self?.state = newState }
    }
}

enum JITAvailability: Equatable {
    case checking
    case available(String)
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .checking: return "Checking JIT"
        case .available(let path): return path
        case .unavailable(let message): return message
        }
    }
}

/// Centralizes SideStore, StikDebug, and jailbreak JIT paths.
final class JITService: ObservableObject {
    @Published private(set) var availability: JITAvailability = .checking
    @Published private(set) var entitlements: EntitlementStatus?
    private var poolPrepared = false

    var isAvailable: Bool { availability.isAvailable || jit_check_debugged() }

    func refresh() {
        entitlements = EntitlementStatus.check()
        if StikJITHelper.usesJailbreakSupport {
            madeira_jb_initialize()
        }
        if jit_check_debugged() || entitlements?.automaticJIT == true {
            availability = .available(StikJITHelper.usesJailbreakSupport ? "Jailbreak JIT active" : "JIT active")
        } else if StikJITHelper.usesLegacyJIT {
            availability = .unavailable("Enable JIT with SideStore")
        } else if StikJITHelper.isAvailable {
            availability = .unavailable("Enable JIT with StikDebug")
        } else {
            availability = .unavailable("JIT helper unavailable")
        }
    }

    func enable(completion: @escaping (Bool) -> Void) {
        StikJITHelper.enableJIT { [weak self] success in
            DispatchQueue.main.async {
                self?.refresh()
                completion(success)
            }
        }
    }

    func test(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = jit_test_execute()
            let message: String
            switch result {
            case 42: message = "JIT execution test passed"
            case -2: message = "JIT execution is not enabled"
            default: message = "JIT execution test failed (\(result))"
            }
            DispatchQueue.main.async {
                self?.refresh()
                completion(message)
            }
        }
    }

    func preparePool(megabytes: Int) -> Bool {
        if poolPrepared { return true }
        guard isAvailable else { return false }
        guard let pool = StikJITHelper.allocatePool(poolSize: megabytes * 1024 * 1024) else { return false }
        setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
        setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
        setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
        StikJITHelper.detachDebugger()
        poolPrepared = true
        return true
    }
}

/// Converts a library shortcut into one validated native launch configuration.
final class GameLauncher {
    private let library: GameLibraryStore

    init(library: GameLibraryStore) {
        self.library = library
    }

    func configuration(for game: LibraryGame) throws -> WineLaunchConfiguration {
        guard game.isTool || game.kind == .custom || game.kind == .steam || game.kind == .stray || game.kind == .thumper else {
            throw LibraryImportError.notExecutable
        }
        guard library.isInstalled(game) else {
            throw LibraryImportError.notExecutable
        }

        switch game.kind {
        case .desktop:
            return WineLaunchConfiguration(
                executable: "explorer.exe",
                arguments: "/desktop=shell,1024x768 C:\\windows\\system32\\services.exe",
                environment: ["MADEIRA_DESKTOP": "1", "MADEIRA_SCREEN_W": "1024", "MADEIRA_SCREEN_H": "768", "FNA3D_FORCE_DRIVER": "D3D11"]
            )
        default:
            if !game.isTool {
                guard let url = library.localURL(for: game.executable),
                      FileManager.default.fileExists(atPath: url.path) else {
                    throw LibraryImportError.notExecutable
                }
            }
            return WineLaunchConfiguration(
                executable: game.executable,
                arguments: game.arguments,
                environment: ["FNA3D_FORCE_DRIVER": "D3D11"]
            )
        }
    }
}

/// Thin input facade used by the play surface and controls. Raw UIKit touch
/// delivery remains in MetalBackedView because the renderer requires that
/// window-level host arrangement.
final class InputService: ObservableObject {
    @Published var relativePointer: Bool {
        didSet { InputSettings.shared.relative = relativePointer }
    }
    @Published var controlsVisible: Bool {
        didSet { TouchControlsModel.shared.visible = controlsVisible }
    }

    init() {
        relativePointer = InputSettings.shared.relative
        controlsVisible = TouchControlsModel.shared.visible
    }

    func sendKey(_ key: Int32, down: Bool) {
        winios_post_key(key, down ? 1 : 0)
    }

    func tapKey(_ key: Int32) {
        sendKey(key, down: true)
        sendKey(key, down: false)
    }

    func toggleKeyboard() {
        MetalBackedView.toggleKeyboard()
    }
}

/// Opt-in diagnostics facade. The bounded LogStore is only created when a
/// user opens diagnostics or enables developer logging.
final class DiagnosticsStore: ObservableObject {
    static let shared = DiagnosticsStore()

    @Published private(set) var entries: [LogStore.LogEntry] = []
    @Published var developerLogging: Bool {
        didSet {
            UserDefaults.standard.set(developerLogging, forKey: "madeira.diagnostics.enabled")
            setenv("MADEIRA_DIAGNOSTICS", developerLogging ? "1" : "0", 1)
            madeira_set_diag_enabled(developerLogging ? 1 : 0)
            if !developerLogging { entries = [] }
        }
    }

    private init() {
        developerLogging = UserDefaults.standard.bool(forKey: "madeira.diagnostics.enabled")
        setenv("MADEIRA_DIAGNOSTICS", developerLogging ? "1" : "0", 1)
        madeira_set_diag_enabled(developerLogging ? 1 : 0)
    }

    func open() {
        developerLogging = true
        refresh()
    }

    func refresh() {
        guard developerLogging else { entries = []; return }
        entries = Array(LogStore.shared.entries.suffix(200))
    }

    func clear() {
        LogStore.shared.clear()
        refresh()
    }
}
