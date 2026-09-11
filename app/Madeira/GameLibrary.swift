import Foundation
import Combine

struct LibraryGame: Identifiable, Codable, Equatable {
    enum LaunchKind: String, Codable {
        case custom
        case desktop
        case cube
        case clock
        case triangle
        // Kept for decoding older library files. New installs do not add these
        // entries automatically.
        case steam
        case stray
        case thumper
    }

    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var palette: Int
    var kind: LaunchKind
    var executable: String
    var arguments: String = ""
    var favorite: Bool = false
    var lastPlayed: Date?

    static let tools: [LibraryGame] = [
        .init(id: "desktop", title: "Windows desktop", subtitle: "Open the Wine environment",
              symbol: "display", palette: 0, kind: .desktop, executable: "explorer.exe"),
        .init(id: "cube", title: "Graphics test", subtitle: "x64 · DirectX 11",
              symbol: "cube.transparent", palette: 2, kind: .cube, executable: "cube-x64.exe"),
        .init(id: "clock", title: "Clock test", subtitle: "Check Windows timing",
              symbol: "clock", palette: 1, kind: .clock, executable: "clocktest-x64.exe"),
        .init(id: "triangle", title: "ARM graphics test", subtitle: "ARM64 · DirectX 11",
              symbol: "triangle", palette: 3, kind: .triangle, executable: "triangle.exe")
    ]

    var isTool: Bool {
        switch kind {
        case .custom, .steam, .stray, .thumper: return false
        case .desktop, .cube, .clock, .triangle: return true
        }
    }
}

enum LibraryImportError: LocalizedError {
    case noExecutable
    case notExecutable
    case unreadable
    case containsDestination
    case symbolicLink
    case pathOutsideWineDrive

    var errorDescription: String? {
        switch self {
        case .noExecutable:
            return "This folder has no Windows .exe files. Choose the folder containing the installed game."
        case .notExecutable:
            return "Select a Windows .exe file. To keep DLLs and assets together, import the whole game folder."
        case .unreadable:
            return "This selection could not be read. Download it locally in Files and try again."
        case .containsDestination:
            return "Choose an individual game folder, not Madeira's Documents or C drive."
        case .symbolicLink:
            return "This folder contains a symbolic link. Import a folder with the actual game files instead."
        case .pathOutsideWineDrive:
            return "The shortcut must stay inside Madeira's Wine C drive."
        }
    }
}

/// Persistent shortcuts only. Removing a shortcut never removes imported files.
final class GameLibraryStore: ObservableObject {
    @Published private(set) var games: [LibraryGame] = []
    @Published var errorMessage: String?

    let documents: URL
    private let fileManager = FileManager.default
    private var canSave = true

    private var libraryURL: URL { documents.appendingPathComponent("madeira-library.json") }
    var driveC: URL { documents.appendingPathComponent("wine/drive_c", isDirectory: true) }

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.documents = documents
        guard fileManager.fileExists(atPath: libraryURL.path) else { return }

        do {
            games = try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: libraryURL))
        } catch {
            canSave = false
            errorMessage = "Your saved library could not be read. The original file has been kept."
        }
    }

    /// Resolves only a Windows C: path under this app's Wine prefix.
    func localURL(for windowsPath: String) -> URL? {
        let normalized = windowsPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 3,
              normalized.prefix(3).lowercased() == "c:/",
              !normalized.contains("\0") else { return nil }

        let relative = String(normalized.dropFirst(3))
        let root = driveC.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = root.appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resultPath = resolved.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard resultPath == rootPath || resultPath.hasPrefix(rootPath + "/") else { return nil }
        return resolved
    }

    func isInstalled(_ game: LibraryGame) -> Bool {
        if game.kind == .desktop { return true } // explorer.exe is part of Wine.
        if game.isTool {
            return bundledToolExists(game.executable) || localURL(for: "C:/windows/system32/\(game.executable)").map {
                fileManager.fileExists(atPath: $0.path)
            } == true
        }
        guard let url = localURL(for: game.executable) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func toggleFavorite(_ game: LibraryGame) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        var updated = games
        updated[index].favorite.toggle()
        _ = save(updated)
    }

    func markPlayed(_ game: LibraryGame) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        var updated = games
        updated[index].lastPlayed = Date()
        _ = save(updated)
    }

    func remove(_ game: LibraryGame) {
        _ = save(games.filter { $0.id != game.id })
    }

    /// Kept for callers that want to refresh filesystem-backed status without
    /// rewriting the shortcut JSON.
    func refreshFiles() { objectWillChange.send() }

    @discardableResult
    func add(title: String, executable: String, arguments: String = "") -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPath = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              cleanPath.lowercased().hasSuffix(".exe"),
              let url = localURL(for: cleanPath),
              fileManager.fileExists(atPath: url.path) else {
            errorMessage = "Select an .exe inside Madeira's C drive before adding the shortcut."
            return false
        }

        let game = LibraryGame(
            id: UUID().uuidString,
            title: cleanTitle,
            subtitle: "Windows game",
            symbol: "gamecontroller.fill",
            palette: games.count % 4,
            kind: .custom,
            executable: cleanPath,
            arguments: arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return save(games + [game])
    }

    @discardableResult
    private func save(_ updated: [LibraryGame]) -> Bool {
        guard canSave else {
            errorMessage = "The saved library needs to be recovered before it can be edited. Your game files are unchanged."
            return false
        }
        do {
            try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            try data.write(to: libraryURL, options: .atomic)
            games = updated
            return true
        } catch {
            errorMessage = "Could not save the library: \(error.localizedDescription)"
            return false
        }
    }

    private func bundledToolExists(_ executable: String) -> Bool {
        let name = URL(fileURLWithPath: executable).deletingPathExtension().lastPathComponent
        return ["aarch64-windows", "arm64ec-windows", "i386-windows"]
            .contains { Bundle.main.url(forResource: name, withExtension: "exe", subdirectory: $0) != nil }
    }

    static func importExecutable(_ source: URL, into driveC: URL) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let file = source.standardizedFileURL.resolvingSymlinksInPath()
        guard file.pathExtension.lowercased() == "exe",
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LibraryImportError.notExecutable
        }

        let root = driveC.standardizedFileURL.resolvingSymlinksInPath()
        if isInside(file, root: root) {
            return windowsPath(for: file, root: root)
        }

        let relative = "Games/\(UUID().uuidString)/\(file.lastPathComponent)"
        let target = driveC.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: target)
        return "C:/\(relative)".replacingOccurrences(of: "/", with: "\\")
    }

    /// Copies a complete game folder so DLLs, configuration, and asset files stay beside its .exe files.
    static func importFolder(_ source: URL, into driveC: URL) throws -> [String] {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationRoot = driveC.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LibraryImportError.unreadable
        }
        guard root != destinationRoot, !isInside(destinationRoot, root: root) else {
            throw LibraryImportError.containsDestination
        }

        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw LibraryImportError.unreadable }

        var executables: [String] = []
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw LibraryImportError.symbolicLink }
            if file.pathExtension.lowercased() == "exe", values.isRegularFile == true {
                let resolvedFile = file.standardizedFileURL.resolvingSymlinksInPath()
                guard isInside(resolvedFile, root: root) else { throw LibraryImportError.pathOutsideWineDrive }
                executables.append(String(resolvedFile.path.dropFirst(root.path.count + 1)))
            }
        }
        guard !executables.isEmpty else { throw LibraryImportError.noExecutable }

        let relative = "Games/\(UUID().uuidString)"
        let target = driveC.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target)
        return executables.sorted().map { "C:/\(relative)/\($0)".replacingOccurrences(of: "/", with: "\\") }
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidatePath = candidate.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func windowsPath(for file: URL, root: URL) -> String {
        "C:/\(file.path.dropFirst(root.path.count + 1))".replacingOccurrences(of: "/", with: "\\")
    }
}

// Compatibility for the existing preview and smoke-test entry points.
typealias GameLibrary = GameLibraryStore
