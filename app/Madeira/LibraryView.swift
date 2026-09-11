import SwiftUI
import UniformTypeIdentifiers

enum MadeiraTheme {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.065)
    static let panel = Color(red: 0.075, green: 0.090, blue: 0.12)
    static let accent = Color(red: 0.73, green: 0.96, blue: 0.38)
    static let muted = Color(red: 0.58, green: 0.63, blue: 0.70)
    static let warning = Color.orange
    static func colors(_ palette: Int) -> [Color] {
        switch palette % 4 {
        case 1: return [Color(red: 0.62, green: 0.24, blue: 0.10), Color(red: 0.17, green: 0.10, blue: 0.16)]
        case 2: return [Color(red: 0.37, green: 0.19, blue: 0.64), Color(red: 0.08, green: 0.06, blue: 0.22)]
        case 3: return [Color(red: 0.13, green: 0.47, blue: 0.38), Color(red: 0.03, green: 0.16, blue: 0.21)]
        default: return [Color(red: 0.13, green: 0.36, blue: 0.57), Color(red: 0.045, green: 0.10, blue: 0.23)]
        }
    }
}

struct LibraryButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18).frame(minHeight: 46)
            .foregroundColor(primary ? MadeiraTheme.background : .white)
            .background(primary ? MadeiraTheme.accent : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Original vector covers: no store artwork, downloads or bundled game assets.
struct GameArtwork: View {
    let game: LibraryGame
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: MadeiraTheme.colors(game.palette), startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, size in
                    let center = CGPoint(x: size.width * 0.70, y: size.height * 0.32)
                    for index in 0..<5 {
                        let radius = min(size.width, size.height) * (0.18 + Double(index) * 0.085)
                        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                          width: radius * 2, height: radius * 2))
                        context.stroke(circle, with: .color(.white.opacity(0.16 - Double(index) * 0.024)), lineWidth: 1)
                    }
                    var horizon = Path()
                    for index in 0..<12 {
                        let x = CGFloat(index) * size.width / 8 - size.width / 4
                        horizon.move(to: CGPoint(x: size.width * 0.62, y: size.height * 0.44))
                        horizon.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for index in 0..<7 {
                        let y = size.height * (0.5 + pow(Double(index) / 6, 2) * 0.5)
                        horizon.move(to: CGPoint(x: 0, y: y))
                        horizon.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(horizon, with: .color(.white.opacity(0.08)), lineWidth: 1)
                }
                Image(systemName: game.symbol)
                    .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.30, weight: .ultraLight))
                    .foregroundColor(.white.opacity(0.82))
                    .rotationEffect(.degrees(-12))
                    .offset(x: geometry.size.width * 0.10, y: -geometry.size.height * 0.07)
                LinearGradient(colors: [.clear, .black.opacity(0.70)], startPoint: .center, endPoint: .bottom)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case library = "Library", favorites = "Favorites", tools = "Tools", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .favorites: return "heart"
        case .tools: return "display"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct LibraryHome: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var library: GameLibrary
    let entitlements: EntitlementStatus?
    let jitReady: Bool
    let activeGame: LibraryGame?
    let sessionBusy: Bool
    let launch: (LibraryGame) -> Void
    let resume: () -> Void
    let enableJIT: () -> Void
    let refreshStatus: () -> Void
    let testJIT: () -> Void
    let jitTestStatus: String
    @State private var section: LibrarySection = .library
    @State private var query = ""
    @State private var selectedGame: LibraryGame?
    @State private var addingGame = false
    @AppStorage("madeira.library.sort") private var sort = "Recent"

    private var visibleGames: [LibraryGame] {
        library.games.filter {
            (section != .favorites || $0.favorite) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }.sorted {
            if sort == "Name" { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if $0.lastPlayed == $1.lastPlayed { return $0.title < $1.title }
            return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 760
            HStack(spacing: 0) {
                if wide { sidebar.frame(width: 216) }
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            header
                            if let game = activeGame, sessionBusy { resumeBanner(game) }
                            switch section {
                            case .library, .favorites: libraryContent
                            case .tools: toolsContent
                            case .settings:
                                LibrarySettings(entitlements: entitlements, jitReady: jitReady,
                                                enableJIT: enableJIT, refresh: refreshStatus,
                                                testJIT: testJIT, jitTestStatus: jitTestStatus,
                                                sessionBusy: sessionBusy)
                            }
                        }
                        .padding(wide ? 32 : 20)
                        .frame(maxWidth: 1250, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    if !wide { bottomBar }
                }
            }
            .background(MadeiraTheme.background.ignoresSafeArea())
        }
        .foregroundColor(.white)
        .tint(MadeiraTheme.accent)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in library.refreshFiles() }
        .sheet(item: $selectedGame) { game in
            GameDetailView(library: library, game: game, sessionBusy: sessionBusy) {
                selectedGame = nil
                launch(game)
            }
        }
        .sheet(isPresented: $addingGame) { AddGameView(library: library) }
        .alert("Library", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack(spacing: 10) {
                Image(systemName: "m.square.fill").font(.system(size: 33)).foregroundColor(MadeiraTheme.accent)
                Text("madeira").font(.system(size: 25, weight: .bold, design: .rounded))
            }
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR SPACE").font(.system(size: 10, weight: .bold)).tracking(2).foregroundColor(MadeiraTheme.muted).padding(12)
                ForEach(LibrarySection.allCases) { item in navigationButton(item) }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "gamecontroller").font(.title2).foregroundColor(MadeiraTheme.accent)
                Text("Bring your games.").font(.subheadline.weight(.semibold))
                Text("Add a Windows game folder and make it yours.").font(.caption).foregroundColor(MadeiraTheme.muted)
                Button { addingGame = true } label: { Label("Add game", systemImage: "plus") }
                    .buttonStyle(LibraryButtonStyle(primary: true))
            }
            .padding(16).background(MadeiraTheme.panel).cornerRadius(16)
            HStack(spacing: 7) {
                Circle().fill(jitReady ? MadeiraTheme.accent : .orange).frame(width: 6, height: 6)
                Text(jitReady ? "JIT ready" : "JIT needs setup").font(.caption)
            }
            .foregroundColor(MadeiraTheme.muted)
        }
        .padding(20)
        .background(Color.white.opacity(0.018))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
    }

    private func navigationButton(_ item: LibrarySection) -> some View {
        Button { section = item; query = "" } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol).frame(width: 22)
                Text(item.rawValue).font(.subheadline.weight(.semibold))
                Spacer()
                if item == .library { Text("\(library.games.count)").font(.caption.monospacedDigit()) }
            }
            .padding(13)
            .foregroundColor(section == item ? MadeiraTheme.accent : MadeiraTheme.muted)
            .background(section == item ? MadeiraTheme.accent.opacity(0.09) : .clear)
            .cornerRadius(12)
        }.buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(LibrarySection.allCases) { item in
                Button { section = item; query = "" } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.symbol).font(.system(size: 19))
                        Text(item.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundColor(section == item ? MadeiraTheme.accent : MadeiraTheme.muted)
                }.buttonStyle(.plain)
            }
        }
        .background(MadeiraTheme.panel)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MADEIRA / \(section == .settings ? "PREFERENCES" : "PLAY YOUR WAY")")
                    .font(.system(size: 10, weight: .bold)).tracking(2).foregroundColor(MadeiraTheme.muted)
                Text(section.rawValue).font(.system(size: 34, weight: .bold, design: .rounded))
            }
            Spacer()
            if section == .library || section == .favorites {
                Button { addingGame = true } label: { Label("Add game", systemImage: "plus") }
                    .buttonStyle(LibraryButtonStyle(primary: true))
            }
        }
    }

    @ViewBuilder private var libraryContent: some View {
        if section == .library && query.isEmpty { hero }
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(MadeiraTheme.muted)
                TextField("Search your library", text: $query).font(.subheadline).autocorrectionDisabled()
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
            }
            .padding(13).background(MadeiraTheme.panel).cornerRadius(12)
            Menu {
                Picker("Sort games", selection: $sort) { Text("Recently played").tag("Recent"); Text("Name").tag("Name") }
            } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 46, height: 46).background(MadeiraTheme.panel).cornerRadius(12) }
            .accessibilityLabel("Sort games")
        }
        HStack {
            Text(section == .favorites ? "Your favorites" : "All games").font(.title3.weight(.semibold))
            Text("\(visibleGames.count)").font(.caption.weight(.bold)).foregroundColor(MadeiraTheme.muted)
            Spacer()
        }
        if visibleGames.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: query.isEmpty ? "gamecontroller" : "magnifyingglass").font(.system(size: 38, weight: .light)).foregroundColor(MadeiraTheme.accent)
                Text(query.isEmpty ? (section == .favorites ? "Keep your favorites close." : "Your next adventure belongs here.") : "No games found.").font(.headline)
                Text(query.isEmpty ? "Add a game or tap the heart on a game card." : "Try another title.").font(.subheadline).foregroundColor(MadeiraTheme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 55)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 145 : 180, maximum: 290), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(visibleGames) { game in
                    GameCard(game: game, installed: library.isInstalled(game), select: { selectedGame = game }, favorite: { library.toggleFavorite(game) })
                }
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            GameArtwork(game: .init(id: "hero", title: "", subtitle: "", symbol: "sparkles", palette: 3, kind: .custom, executable: ""))
            LinearGradient(colors: [Color.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                Text("A LITTLE ESCAPE.").font(.system(size: 10, weight: .bold)).tracking(2.5).foregroundColor(MadeiraTheme.accent)
                Text("Big worlds.\nYour screen.").font(.system(size: 36, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                Text("Your Windows games, together in one place.")
                    .font(.subheadline).foregroundColor(.white.opacity(0.65)).frame(maxWidth: 240, alignment: .leading)
                Button { addingGame = true } label: { Label("Build your library", systemImage: "plus") }
                    .buttonStyle(LibraryButtonStyle(primary: true))
            }
            .padding(26)
        }
        .frame(height: 285).clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func resumeBanner(_ game: LibraryGame) -> some View {
        Button(action: resume) {
            HStack(spacing: 14) {
                Image(systemName: "play.circle.fill").font(.title).foregroundColor(MadeiraTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Return to \(game.title)").font(.headline)
                    Text("Your session is still open").font(.caption).foregroundColor(MadeiraTheme.muted)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .padding(18).background(MadeiraTheme.accent.opacity(0.08)).cornerRadius(16)
        }.buttonStyle(.plain)
    }

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A desktop when you need it. Checks when you don't.").foregroundColor(MadeiraTheme.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(LibraryGame.tools) { game in
                    Button { launch(game) } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: game.symbol).font(.system(size: 30, weight: .light)).foregroundColor(MadeiraTheme.accent)
                            Text(game.title).font(.headline)
                            Text(game.subtitle).font(.caption).foregroundColor(MadeiraTheme.muted)
                            Label("Launch", systemImage: "arrow.up.right").font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(22).background(MadeiraTheme.panel).cornerRadius(18)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct GameCard: View {
    let game: LibraryGame
    let installed: Bool
    let select: () -> Void
    let favorite: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Button(action: select) {
                    ZStack(alignment: .bottomLeading) {
                        GameArtwork(game: game)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("WINDOWS").font(.system(size: 9, weight: .bold)).tracking(2).foregroundColor(.white.opacity(0.55))
                            Text(game.title.uppercased()).font(.system(size: 24, weight: .black, design: .rounded)).foregroundColor(.white)
                        }.padding(18)
                    }
                    .frame(height: 235).clipShape(RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityLabel("Open \(game.title)")
                Button(action: favorite) {
                    Image(systemName: game.favorite ? "heart.fill" : "heart")
                        .foregroundColor(game.favorite ? MadeiraTheme.accent : .white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.25)).clipShape(Circle())
                }.buttonStyle(.plain).padding(8).accessibilityLabel(game.favorite ? "Remove from favorites" : "Add to favorites")
            }
            Button(action: select) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Label(installed ? "Files available" : "Add game files", systemImage: installed ? "checkmark.circle" : "folder.badge.plus")
                        .font(.caption).foregroundColor(installed ? MadeiraTheme.accent : MadeiraTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
    }
}

private struct GameDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: GameLibrary
    let game: LibraryGame
    let sessionBusy: Bool
    let play: () -> Void
    @State private var confirmingRemoval = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GameArtwork(game: game).frame(height: 245).clipShape(RoundedRectangle(cornerRadius: 22))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.title).font(.largeTitle.bold())
                        Text(game.subtitle).foregroundColor(MadeiraTheme.muted)
                    }
                    HStack {
                        Button(action: play) { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(LibraryButtonStyle(primary: true)).disabled(!library.isInstalled(game))
                        Button { library.toggleFavorite(game) } label: {
                            Image(systemName: library.games.first(where: { $0.id == game.id })?.favorite == true ? "heart.fill" : "heart")
                        }.buttonStyle(LibraryButtonStyle()).accessibilityLabel("Toggle favorite")
                    }
                    if !library.isInstalled(game) {
                        Label("Game files needed", systemImage: "folder.badge.plus").font(.headline)
                        Text("This is a launch preset. Copy your installed game folder to the path below using Files, or use Add game to import a folder and create your own shortcut.")
                            .font(.subheadline).foregroundColor(MadeiraTheme.muted)
                    }
                    Text("EXECUTABLE").font(.caption.weight(.bold)).tracking(1.5).foregroundColor(MadeiraTheme.muted)
                    Text(game.executable).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let date = game.lastPlayed { Text("Last played \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundColor(MadeiraTheme.muted) }
                    Text("Game compatibility varies. Files available means the executable was found; it does not guarantee the game will run.")
                        .font(.caption).foregroundColor(MadeiraTheme.muted)
                    Button("Remove from library", role: .destructive) { confirmingRemoval = true }.padding(.top, 10)
                }.padding(24)
            }
            .background(MadeiraTheme.background)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove this shortcut? Game files will stay on your device.", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove shortcut", role: .destructive) { library.remove(game); dismiss() }
            }
        }.preferredColorScheme(.dark).tint(MadeiraTheme.accent)
    }
}

private enum GamePickerMode: String, Identifiable {
    case executable, folder
    var id: String { rawValue }
}

/// Present Files directly so Open and Cancel always reach our own delegate.
/// A fresh controller per mode keeps folder/executable filters independent.
private struct GameFilePicker: UIViewControllerRepresentable {
    let mode: GamePickerMode
    let directory: URL
    let selected: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .item also permits executables whose provider has no specific UTType.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: mode == .folder ? [.folder] : [.item], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        if FileManager.default.fileExists(atPath: directory.path) { picker.directoryURL = directory }
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL?) -> Void
        init(selected: @escaping (URL?) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            selected(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
    }
}

private struct AddGameView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: GameLibrary
    @State private var title = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var activePicker: GamePickerMode?
    @State private var importingFolder = false
    @State private var importing = false
    @State private var candidates: [String] = []
    @State private var error: String?
    @State private var selectionNote: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Bring your next adventure.", systemImage: "gamecontroller").font(.title3.weight(.semibold)).padding(.vertical, 8)
                    Text("Select a Windows .exe to add it. If the game needs DLLs or other assets, import its entire folder first, then choose the executable.")
                        .font(.subheadline).foregroundColor(MadeiraTheme.muted)
                    Button { activePicker = .executable } label: {
                        HStack { Label("Select executable (.exe)", systemImage: "doc.badge.plus"); Spacer(); if importing && !importingFolder { ProgressView() } }
                    }.disabled(importing)
                    Button { activePicker = .folder } label: {
                        HStack { Label("Import game folder", systemImage: "folder.badge.plus"); Spacer(); if importing && importingFolder { ProgressView() } }
                    }.disabled(importing)
                }
                Section {
                    TextField("Game name", text: $title)
                    if candidates.count > 1 {
                        Picker("Executable", selection: $executable) {
                            Text("Choose an .exe…").tag("")
                            ForEach(candidates, id: \.self) { path in
                                Text(path.components(separatedBy: "\\").dropFirst(3).joined(separator: "\\")).tag(path)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    if let selectionNote { Text(selectionNote).font(.caption).foregroundColor(MadeiraTheme.muted) }
                    TextField("C:\\Games\\MyGame\\game.exe", text: $executable).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Launch arguments (optional)", text: $arguments).autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: { Text("Shortcut") } footer: {
                    Text("Executables already in Madeira's C drive are linked in place with their game files. External executables are copied individually. Imported files stay in C:\\Games if you cancel.")
                }
                if let error { Section { Text(error).foregroundColor(.orange) } }
            }
            .scrollContentBackground(.hidden).background(MadeiraTheme.background)
            .navigationTitle("Add game").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        if library.add(title: title, executable: executable, arguments: arguments) { dismiss() }
                        else { error = library.errorMessage; library.errorMessage = nil }
                    }.disabled(importing || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || executable.isEmpty)
                }
            }
            .sheet(item: $activePicker) { mode in
                GameFilePicker(mode: mode, directory: library.driveC) { url in
                    activePicker = nil
                    if let url { beginImport(url, folder: mode == .folder) }
                }
            }
            .interactiveDismissDisabled(importing)
        }.preferredColorScheme(.dark).tint(MadeiraTheme.accent)
    }

    private func beginImport(_ url: URL, folder: Bool) {
        // Take scoped access in the selection callback, before Files dismisses.
        let access = url.startAccessingSecurityScopedResource()
        importing = true
        importingFolder = folder
        error = nil
        candidates = []
        executable = ""
        selectionNote = "Selected: \(url.lastPathComponent). \(folder ? "Reading and importing game files…" : "Adding executable…")"
        if title.isEmpty { title = folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
        let destination = library.driveC
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let imported = Result {
                if folder { return try GameLibrary.importFolder(url, into: destination) }
                return [try GameLibrary.importExecutable(url, into: destination)]
            }
            DispatchQueue.main.async {
                importing = false
                switch imported {
                case .success(let paths):
                    candidates = paths
                    executable = paths.count == 1 ? paths[0] : ""
                    selectionNote = folder
                        ? (paths.count > 1 ? "Folder imported. Tap Executable to choose which .exe to launch." : "Folder imported with its game files.")
                        : "Executable selected. Files already in Madeira are linked in place; external .exe files are copied individually."
                case .failure(let failure):
                    selectionNote = "Selected: \(url.lastPathComponent). Import could not finish."
                    error = failure.localizedDescription
                }
            }
        }
    }
}

struct LibrarySettings: View {
    let entitlements: EntitlementStatus?
    let jitReady: Bool
    let enableJIT: () -> Void
    let refresh: () -> Void
    let testJIT: () -> Void
    let jitTestStatus: String
    let sessionBusy: Bool
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @State private var guide = false
    @State private var logs = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsGroup("Runtime", subtitle: "Capabilities reported by this installation") {
                capability("JIT", detail: "Required to translate Windows code", enabled: jitReady)
                capability("Extra memory", detail: "A higher app memory limit", enabled: entitlements.map { $0.increasedMemory || $0.automaticMemory } ?? false)
                capability("Extended address space", detail: "More virtual addresses, not more physical RAM", enabled: entitlements?.extendedVA ?? false)
                HStack {
                    Button("Enable JIT", action: enableJIT).buttonStyle(LibraryButtonStyle(primary: true)).disabled(sessionBusy)
                    Button("Refresh", action: refresh).buttonStyle(LibraryButtonStyle())
                }
                if entitlements?.jailbroken == true {
                    Text("Jailbreak detected. Memory capabilities still depend on the entitlements preserved by your installer.")
                        .font(.caption).foregroundColor(MadeiraTheme.muted)
                }
            }
            settingsGroup("Controls", subtitle: "Applied immediately and saved on this device") {
                Toggle("Relative pointer / mouse look", isOn: $input.relative)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Pointer sensitivity"); Spacer(); Text(String(format: "%.2f", input.relative ? input.sensRel : input.sensAbs)).monospacedDigit() }
                    Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.10...8)
                }
                Toggle("On-screen game controls", isOn: $controls.visible)
                Text("In landscape play, tap the pencil to move, resize and map your touch controls.").font(.caption).foregroundColor(MadeiraTheme.muted)
            }
            settingsGroup("Help & diagnostics", subtitle: "Setup instructions and runtime troubleshooting") {
                Button { guide = true } label: { Label("Setup guide", systemImage: "book.closed") }.buttonStyle(LibraryButtonStyle())
                Button { logs = true } label: { Label("Open logs", systemImage: "terminal") }.buttonStyle(LibraryButtonStyle())
                Toggle("Detailed runtime diagnostics", isOn: $input.diagnostics)
                Text("Detailed diagnostics can slow games down. Enable them when investigating a problem.").font(.caption).foregroundColor(MadeiraTheme.muted)
                HStack {
                    Button("Test JIT", action: testJIT).buttonStyle(LibraryButtonStyle()).disabled(sessionBusy)
                    Text(jitTestStatus).font(.caption).foregroundColor(MadeiraTheme.muted)
                }
            }
            Text("MADEIRA  ·  Windows games on iOS\nPowered by Wine, FEX and Metal graphics translation.")
                .font(.caption).foregroundColor(MadeiraTheme.muted).lineSpacing(6)
        }
        .sheet(isPresented: $guide) { SetupGuideView() }
        .sheet(isPresented: $logs) { LibraryLogsView() }
    }

    private func settingsGroup<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundColor(MadeiraTheme.muted)
            }
            content()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(MadeiraTheme.panel).cornerRadius(20)
    }

    private func capability(_ name: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(enabled ? MadeiraTheme.accent : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundColor(MadeiraTheme.muted)
            }
            Spacer()
            Text(enabled ? "Enabled" : "Unavailable").font(.caption).foregroundColor(enabled ? MadeiraTheme.accent : MadeiraTheme.muted)
        }
    }
}

struct LibraryLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LogStore.shared
    @State private var query = ""
    @State private var errorsOnly = false
    private var entries: [LogStore.LogEntry] {
        store.entries.filter { (!errorsOnly || $0.level == .error) && (query.isEmpty || $0.lastRaw.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Toggle("Errors only", isOn: $errorsOnly).padding()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if entries.isEmpty { Text("No matching log entries.").foregroundColor(MadeiraTheme.muted).padding() }
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.level.rawValue).foregroundColor(entry.level == .error ? .orange : MadeiraTheme.accent)
                                    Text(entry.lastTimestamp, style: .time).foregroundColor(MadeiraTheme.muted)
                                    if entry.count > 1 { Text("×\(entry.count)").foregroundColor(MadeiraTheme.muted) }
                                }.font(.caption2.monospaced())
                                Text(entry.lastRaw).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(MadeiraTheme.panel).cornerRadius(10)
                        }
                    }.padding(.horizontal)
                }
            }
            .background(MadeiraTheme.background)
            .searchable(text: $query, prompt: "Search logs")
            .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Clear") { store.clear() } }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ShareLink(item: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("madeira-log.txt")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button("Done") { dismiss() }
                }
            }
        }.preferredColorScheme(.dark).tint(MadeiraTheme.accent)
    }
}
