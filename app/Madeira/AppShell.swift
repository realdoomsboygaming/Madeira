import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library: GameLibraryStore
    @StateObject private var jit: JITService
    @StateObject private var runtime: RuntimeService
    @StateObject private var input: InputService
    @StateObject private var diagnostics: DiagnosticsStore
    @State private var playGame: LibraryGame?
    @State private var pendingLaunch: WineLaunchConfiguration?
    @State private var launchError: String?

    init() {
        let library = GameLibraryStore()
        let jit = JITService()
        _library = StateObject(wrappedValue: library)
        _jit = StateObject(wrappedValue: jit)
        _runtime = StateObject(wrappedValue: RuntimeService(jit: jit))
        _input = StateObject(wrappedValue: InputService())
        _diagnostics = StateObject(wrappedValue: DiagnosticsStore.shared)
    }

    var body: some View {
        ZStack {
            LibraryRootView(
                library: library,
                jit: jit,
                runtime: runtime,
                input: input,
                diagnostics: diagnostics,
                launch: launch,
                openPlay: { game, configuration in
                    pendingLaunch = configuration
                    playGame = game
                }
            )
            .opacity(playGame == nil ? 1 : 0)
            .allowsHitTesting(playGame == nil)

            if let game = playGame {
                GamePlayView(
                    game: game,
                    runtime: runtime,
                    input: input,
                    onReady: startPendingLaunch,
                    onClose: leavePlay
                )
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(MadeiraTheme.accent)
        .background(MadeiraTheme.background.ignoresSafeArea())
        .onAppear {
            // Bring up the bounded file log before touching jailbreak/JIT
            // helpers. A native failure after this point leaves a persistent
            // startup marker even when the system crash reporter is absent.
            LogStore.shared.log("Madeira UI started")
            jit_install_trap_handler()
            jit.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            jit.refresh()
            runtime.refresh()
        }
        .alert("Madeira", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    private func launch(_ game: LibraryGame) {
        do {
            let configuration = try GameLauncher(library: library).configuration(for: game)
            pendingLaunch = configuration
            playGame = game
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func startPendingLaunch() {
        guard let configuration = pendingLaunch, let game = playGame else { return }
        pendingLaunch = nil
        let poolMB = UserDefaults.standard.integer(forKey: "madeira.jit.pool.mb")
        runtime.start(configuration: configuration, poolSizeMB: poolMB == 0 ? 896 : poolMB) { result in
            if case .success = result { library.markPlayed(game) }
            if case .failure(let error) = result { launchError = error.localizedDescription }
        }
    }

    private func leavePlay() {
        MetalBackedView.setPresentationVisible(false)
        playGame = nil
        pendingLaunch = nil
    }
}

/// Entry point used only by the simulator preview target. It exercises the
/// same library and settings screens without starting Wine or the Metal host.
struct MadeiraPreviewScreen: View {
    let settings: Bool
    @StateObject private var library = GameLibraryStore()
    @StateObject private var jit = JITService()
    @StateObject private var runtime: RuntimeService
    @StateObject private var input = InputService()
    @StateObject private var diagnostics = DiagnosticsStore.shared

    init(settings: Bool) {
        self.settings = settings
        let jit = JITService()
        _jit = StateObject(wrappedValue: jit)
        _runtime = StateObject(wrappedValue: RuntimeService(jit: jit))
    }

    var body: some View {
        LibraryRootView(
            library: library,
            jit: jit,
            runtime: runtime,
            input: input,
            diagnostics: diagnostics,
            launch: { _ in },
            openPlay: { _, _ in },
            initialPage: settings ? .settings : .library
        )
        .preferredColorScheme(.dark)
        .tint(MadeiraTheme.accent)
        .onAppear { jit.refresh() }
    }
}

private enum LibraryPage: String, CaseIterable, Identifiable {
    case library = "Library"
    case favorites = "Favorites"
    case tools = "Tools"
    case settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .favorites: return "heart"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }
}

private struct LibraryRootView: View {
    @ObservedObject var library: GameLibraryStore
    @ObservedObject var jit: JITService
    @ObservedObject var runtime: RuntimeService
    @ObservedObject var input: InputService
    @ObservedObject var diagnostics: DiagnosticsStore
    let launch: (LibraryGame) -> Void
    let openPlay: (LibraryGame, WineLaunchConfiguration) -> Void
    let initialPage: LibraryPage

    @State private var page: LibraryPage
    @State private var query = ""
    @State private var sortByName = false
    @State private var selectedGame: LibraryGame?
    @State private var showImporter = false

    init(library: GameLibraryStore,
         jit: JITService,
         runtime: RuntimeService,
         input: InputService,
         diagnostics: DiagnosticsStore,
         launch: @escaping (LibraryGame) -> Void,
         openPlay: @escaping (LibraryGame, WineLaunchConfiguration) -> Void,
         initialPage: LibraryPage = .library) {
        self.library = library
        self.jit = jit
        self.runtime = runtime
        self.input = input
        self.diagnostics = diagnostics
        self.launch = launch
        self.openPlay = openPlay
        self.initialPage = initialPage
        _page = State(initialValue: initialPage)
    }

    private var games: [LibraryGame] {
        let filtered = library.games.filter {
            (page != .favorites || $0.favorite) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
        return filtered.sorted {
            if sortByName { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            HStack(spacing: 0) {
                if wide { sidebar }
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            header
                            if page == .library || page == .favorites { libraryPage }
                            if page == .tools { toolsPage }
                            if page == .settings {
                                SettingsScreen(jit: jit, runtime: runtime, input: input, diagnostics: diagnostics)
                            }
                        }
                        .padding(wide ? 32 : 20)
                        .frame(maxWidth: 1260, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    if !wide { bottomNavigation }
                }
            }
            .background(MadeiraTheme.background.ignoresSafeArea())
        }
        .foregroundColor(.white)
        .sheet(item: $selectedGame) { game in
            GameDetailsScreen(game: game, library: library, launch: launch)
        }
        .sheet(isPresented: $showImporter) {
            GameImportScreen(library: library)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "m.square.fill").font(.system(size: 32)).foregroundColor(MadeiraTheme.accent)
                Text("madeira").font(.system(size: 25, weight: .bold, design: .rounded))
            }
            ForEach(LibraryPage.allCases) { item in navigationButton(item) }
            Spacer()
            Button { showImporter = true } label: {
                Label("Import game", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(MadeiraButtonStyle(primary: true))
            RuntimeBadge(jit: jit, runtime: runtime)
        }
        .padding(22)
        .frame(width: 220)
        .background(Color.white.opacity(0.018))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
    }

    private func navigationButton(_ item: LibraryPage) -> some View {
        Button { page = item; query = "" } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol).frame(width: 22)
                Text(item.rawValue).font(.subheadline.weight(.semibold))
                Spacer()
                if item == .library { Text("\(library.games.count)").font(.caption.monospacedDigit()) }
            }
            .padding(12)
            .foregroundColor(page == item ? MadeiraTheme.accent : MadeiraTheme.muted)
            .background(page == item ? MadeiraTheme.accent.opacity(0.10) : .clear)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            ForEach(LibraryPage.allCases) { item in
                Button { page = item; query = "" } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.symbol)
                        Text(item.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .foregroundColor(page == item ? MadeiraTheme.accent : MadeiraTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .background(MadeiraTheme.panel)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page == .settings ? "MADEIRA / PREFERENCES" : "MADEIRA / PLAY YOUR WAY")
                    .font(.system(size: 10, weight: .bold)).tracking(2).foregroundColor(MadeiraTheme.muted)
                Text(page.rawValue).font(.system(size: 34, weight: .bold, design: .rounded))
            }
            Spacer()
            if page == .library || page == .favorites {
                Button { showImporter = true } label: { Label("Import", systemImage: "plus") }
                    .buttonStyle(MadeiraButtonStyle(primary: true))
            }
        }
    }

    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(MadeiraTheme.muted)
                    TextField("Search games", text: $query).autocorrectionDisabled()
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } }
                }
                .padding(13).background(MadeiraTheme.panel).cornerRadius(12)
                Button { sortByName.toggle() } label: {
                    Image(systemName: sortByName ? "textformat.abc" : "clock.arrow.circlepath")
                        .frame(width: 46, height: 46).background(MadeiraTheme.panel).cornerRadius(12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sortByName ? "Sorted by name" : "Sorted by recent play")
            }
            Text(page == .favorites ? "Your favorites" : (games.isEmpty ? "Your library is ready" : "Installed games"))
                .font(.title3.weight(.semibold))
            if games.isEmpty {
                EmptyLibraryView(favorites: page == .favorites, searching: !query.isEmpty, importGame: { showImporter = true })
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 290), spacing: 16)], spacing: 16) {
                    ForEach(games) { game in
                        LibraryGameCard(game: game, installed: library.isInstalled(game), select: { selectedGame = game }, favorite: { library.toggleFavorite(game) })
                    }
                }
            }
        }
    }

    private var toolsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Runtime tools are shown only when their executable is bundled or present in the Wine prefix.")
                .font(.subheadline).foregroundColor(MadeiraTheme.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(LibraryGame.tools) { tool in
                    let available = library.isInstalled(tool)
                    Button {
                        guard available, let config = try? GameLauncher(library: library).configuration(for: tool) else { return }
                        openPlay(tool, config)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: tool.symbol).font(.system(size: 28, weight: .light)).foregroundColor(MadeiraTheme.accent)
                            Text(tool.title).font(.headline)
                            Text(tool.subtitle).font(.caption).foregroundColor(MadeiraTheme.muted)
                            Label(available ? "Ready" : "Files missing", systemImage: available ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption.weight(.semibold)).foregroundColor(available ? MadeiraTheme.accent : MadeiraTheme.warning)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                        .padding(20).background(MadeiraTheme.panel).cornerRadius(18)
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                }
            }
        }
    }
}

private struct MadeiraButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 17).frame(minHeight: 44)
            .foregroundColor(primary ? MadeiraTheme.background : .white)
            .background(primary ? MadeiraTheme.accent : Color.white.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct RuntimeBadge: View {
    @ObservedObject var jit: JITService
    @ObservedObject var runtime: RuntimeService
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(jit.isAvailable ? "JIT ready" : "JIT unavailable", systemImage: jit.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle")
            Label(runtime.state.label, systemImage: runtime.isActive ? "play.circle.fill" : "circle")
        }
        .font(.caption)
        .foregroundColor(jit.isAvailable ? MadeiraTheme.accent : MadeiraTheme.warning)
    }
}

private struct EmptyLibraryView: View {
    let favorites: Bool
    let searching: Bool
    let importGame: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: searching ? "magnifyingglass" : (favorites ? "heart" : "folder.badge.plus"))
                .font(.system(size: 38, weight: .light)).foregroundColor(MadeiraTheme.accent)
            Text(searching ? "No games found" : (favorites ? "No favorites yet" : "No games imported"))
                .font(.headline)
            Text(searching ? "Try another title." : "Import an .exe or a complete Windows game folder to begin.")
                .font(.subheadline).foregroundColor(MadeiraTheme.muted).multilineTextAlignment(.center)
            if !searching && !favorites {
                Button("Import a game", action: importGame).buttonStyle(MadeiraButtonStyle(primary: true))
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

private struct LibraryGameCard: View {
    let game: LibraryGame
    let installed: Bool
    let select: () -> Void
    let favorite: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button(action: select) {
                VStack(spacing: 12) {
                    Image(systemName: game.symbol).font(.system(size: 34, weight: .light)).foregroundColor(MadeiraTheme.accent)
                    Text(game.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 138)
                .padding(14)
                .background(MadeiraTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            HStack(spacing: 7) {
                Text(installed ? "Ready to play" : "Files missing")
                    .font(.caption).foregroundColor(installed ? MadeiraTheme.accent : MadeiraTheme.warning)
                Spacer()
                Button(action: favorite) {
                    Image(systemName: game.favorite ? "heart.fill" : "heart")
                }.buttonStyle(.plain).foregroundColor(game.favorite ? MadeiraTheme.accent : MadeiraTheme.muted)
            }
        }
    }
}

private struct GameDetailsScreen: View {
    @Environment(\.dismiss) private var dismiss
    let game: LibraryGame
    @ObservedObject var library: GameLibraryStore
    let launch: (LibraryGame) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: game.symbol).font(.system(size: 58, weight: .light)).foregroundColor(MadeiraTheme.accent)
                Text(game.title).font(.system(size: 34, weight: .bold, design: .rounded))
                Text(game.subtitle).foregroundColor(MadeiraTheme.muted)
                Divider().overlay(Color.white.opacity(0.12))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Executable").font(.caption.weight(.semibold)).foregroundColor(MadeiraTheme.muted)
                    Text(game.executable).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Label(library.isInstalled(game) ? "Files ready" : "Files missing", systemImage: library.isInstalled(game) ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundColor(library.isInstalled(game) ? MadeiraTheme.accent : MadeiraTheme.warning)
                Spacer()
                Button {
                    launch(game)
                    dismiss()
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(MadeiraButtonStyle(primary: true))
                .disabled(!library.isInstalled(game))
            }
            .padding(24)
            .background(MadeiraTheme.background.ignoresSafeArea())
            .navigationTitle("Game details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

private struct GamePlayView: View {
    let game: LibraryGame
    @ObservedObject var runtime: RuntimeService
    @ObservedObject var input: InputService
    let onReady: () -> Void
    let onClose: () -> Void
    @State private var didStart = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onClose) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).accessibilityLabel("Return to library")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(game.title).font(.headline).lineLimit(1)
                        Text(runtime.state.label).font(.caption).foregroundColor(MadeiraTheme.muted)
                    }
                    Spacer()
                    if geometry.size.width > 600 { FPSOverlay(compact: true) }
                    Button(action: input.toggleKeyboard) { Image(systemName: "keyboard").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).accessibilityLabel("Toggle keyboard")
                }
                .padding(.horizontal, 12).frame(height: 66).background(MadeiraTheme.panel)

                MadeiraMetalView(onReady: {
                    guard !didStart else { return }
                    didStart = true
                    onReady()
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                HStack(spacing: 10) {
                    playKey("esc", 0x1B)
                    playKey("space", 0x20)
                    playKey("return", 0x0D)
                    JoystickKeyView()
                    Button { input.relativePointer.toggle() } label: {
                        Label(input.relativePointer ? "Mouse look" : "Pointer", systemImage: "cursorarrow")
                    }.buttonStyle(MadeiraButtonStyle())
                    Button { input.controlsVisible.toggle() } label: {
                        Image(systemName: input.controlsVisible ? "gamecontroller.fill" : "gamecontroller")
                    }.buttonStyle(MadeiraButtonStyle()).accessibilityLabel("Toggle touch controls")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(MadeiraTheme.panel)
            }
            .foregroundColor(.white)
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear {
            requestOrientation(landscape: true)
            MetalBackedView.setPresentationVisible(true)
        }
        .onDisappear {
            MetalBackedView.setPresentationVisible(false)
            requestOrientation(landscape: false)
        }
    }

    private func playKey(_ title: String, _ key: Int32) -> some View {
        Button { input.tapKey(key) } label: { Text(title).font(.system(.caption, design: .monospaced)) }
            .buttonStyle(MadeiraButtonStyle())
    }

    private func requestOrientation(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        if #available(iOS 16.0, *) {
            let orientations: UIInterfaceOrientationMask = landscape ? [.landscapeLeft, .landscapeRight] : [.portrait]
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        }
    }
}

private struct SettingsScreen: View {
    @ObservedObject var jit: JITService
    @ObservedObject var runtime: RuntimeService
    @ObservedObject var input: InputService
    @ObservedObject var diagnostics: DiagnosticsStore
    @State private var showDiagnostics = false
    @AppStorage("madeira.jit.pool.mb") private var poolSizeMB = 896

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard("Runtime", "The existing Wine, FEX, ARM64EC, and Metal stack remains unchanged.") {
                statusRow("Runtime", runtime.state.label, runtime.isActive)
                statusRow("JIT", jit.availability.label, jit.isAvailable)
                statusRow("Increased memory", jit.entitlements?.increasedMemory == true || jit.entitlements?.automaticMemory == true ? "Enabled" : "Not granted", jit.entitlements?.increasedMemory == true || jit.entitlements?.automaticMemory == true)
                statusRow("Extended virtual addressing", jit.entitlements?.extendedVA == true ? "Enabled" : "Not granted", jit.entitlements?.extendedVA == true)
                HStack {
                    Button("Enable JIT") { jit.enable { _ in jit.refresh() } }.buttonStyle(MadeiraButtonStyle(primary: true)).disabled(runtime.isActive)
                    Button("Refresh") { jit.refresh() }.buttonStyle(MadeiraButtonStyle())
                    Spacer()
                }
            }

            settingsCard("Memory", "The pool is virtual-address space for Wine/FEX code and images.") {
                Picker("JIT pool", selection: $poolSizeMB) {
                    Text("384 MB · direct games").tag(384)
                    Text("896 MB · desktop/Steam").tag(896)
                    Text("1024 MB · high memory").tag(1024)
                }
                .pickerStyle(.menu)
                Text("A new runtime session uses this value. Physical memory limits still apply.")
                    .font(.caption).foregroundColor(MadeiraTheme.muted)
            }

            settingsCard("Input", "Applied to the native Metal surface and saved for the next session.") {
                Toggle("Relative pointer / mouse look", isOn: $input.relativePointer)
                Toggle("On-screen controls", isOn: $input.controlsVisible)
                Text("Touch, keyboard, pointer, and controller-facing controls stay in the native input bridge.")
                    .font(.caption).foregroundColor(MadeiraTheme.muted)
            }

            settingsCard("Diagnostics", "Disabled by default so logs do not drive normal SwiftUI updates.") {
                Toggle("Developer diagnostics", isOn: $diagnostics.developerLogging)
                Button {
                    diagnostics.open()
                    showDiagnostics = true
                } label: { Label("Open diagnostics", systemImage: "terminal") }
                .buttonStyle(MadeiraButtonStyle())
            }
        }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsScreen(store: diagnostics) }
    }

    private func settingsCard<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundColor(MadeiraTheme.muted)
            }
            content()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(MadeiraTheme.panel).cornerRadius(18)
    }

    private func statusRow(_ name: String, _ value: String, _ good: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: good ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(good ? MadeiraTheme.accent : MadeiraTheme.warning)
            Text(name)
            Spacer()
            Text(value).font(.caption).foregroundColor(good ? MadeiraTheme.accent : MadeiraTheme.muted)
        }
    }
}

private struct DiagnosticsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: DiagnosticsStore
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.level.rawValue).font(.caption2.monospaced()).foregroundColor(entry.level == .error ? .orange : MadeiraTheme.accent)
                            Text(entry.lastTimestamp, style: .time).font(.caption2).foregroundColor(MadeiraTheme.muted)
                            Spacer()
                            if entry.count > 1 { Text("×\(entry.count)").font(.caption2).foregroundColor(MadeiraTheme.muted) }
                        }
                        Text(entry.lastRaw).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    .listRowBackground(MadeiraTheme.panel)
                }
            }
            .scrollContentBackground(.hidden).background(MadeiraTheme.background)
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Clear") { store.clear() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear { store.refresh() }
        }
        .preferredColorScheme(.dark)
    }
}

private enum BaselinePickerMode: String, Identifiable { case executable, folder; var id: String { rawValue } }

private struct BaselineDocumentPicker: UIViewControllerRepresentable {
    let mode: BaselinePickerMode
    let directory: URL
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = mode == .folder ? [.folder] : [.item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        if FileManager.default.fileExists(atPath: directory.path) { picker.directoryURL = directory }
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}

private struct GameImportScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: GameLibraryStore
    @State private var picker: BaselinePickerMode?
    @State private var title = ""
    @State private var executable = ""
    @State private var candidates: [String] = []
    @State private var arguments = ""
    @State private var importing = false
    @State private var message = "Select an .exe or import the complete game folder."
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { picker = .executable } label: {
                        HStack { Label("Select executable (.exe)", systemImage: "doc.badge.plus"); Spacer(); if importing { ProgressView() } }
                    }.disabled(importing)
                    Button { picker = .folder } label: {
                        Label("Import game folder", systemImage: "folder.badge.plus")
                    }.disabled(importing)
                    Text(message).font(.caption).foregroundColor(MadeiraTheme.muted)
                }
                Section("Shortcut") {
                    TextField("Game name", text: $title)
                    if candidates.count > 1 {
                        Picker("Executable", selection: $executable) {
                            Text("Choose an .exe…").tag("")
                            ForEach(candidates, id: \.self) { path in Text(path).tag(path) }
                        }
                    }
                    TextField("C:\\Games\\MyGame\\game.exe", text: $executable)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Launch arguments (optional)", text: $arguments)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                if let error { Section { Text(error).foregroundColor(MadeiraTheme.warning) } }
            }
            .scrollContentBackground(.hidden).background(MadeiraTheme.background)
            .navigationTitle("Import game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { addShortcut() }.disabled(importing || title.isEmpty || executable.isEmpty)
                }
            }
            .sheet(item: $picker) { mode in
                BaselineDocumentPicker(mode: mode, directory: library.driveC) { url in
                    picker = nil
                    guard let url else { message = "Files picker cancelled."; return }
                    beginImport(url, folder: mode == .folder)
                }
            }
            .interactiveDismissDisabled(importing)
        }
        .preferredColorScheme(.dark)
    }

    private func beginImport(_ url: URL, folder: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        importing = true
        error = nil
        candidates = []
        executable = ""
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        }
        message = "Files picker closed. \(folder ? "Scanning and copying the game folder…" : "Copying the executable…")"
        let destination = library.driveC
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result: Result<[String], Error>
            do {
                result = .success(folder
                    ? try GameLibraryStore.importFolder(url, into: destination)
                    : [try GameLibraryStore.importExecutable(url, into: destination)])
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                importing = false
                switch result {
                case .success(let paths):
                    candidates = paths
                    executable = paths.count == 1 ? paths[0] : ""
                    message = paths.count == 1 ? "Import complete. Review the shortcut and tap Add." : "Import complete. Choose which executable should launch."
                case .failure(let failure):
                    message = "Import failed after Files closed."
                    error = failure.localizedDescription
                }
            }
        }
    }

    private func addShortcut() {
        guard library.add(title: title, executable: executable, arguments: arguments) else {
            error = library.errorMessage
            library.errorMessage = nil
            return
        }
        dismiss()
    }
}
