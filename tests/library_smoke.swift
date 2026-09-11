import Foundation

@main
struct LibrarySmokeTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("madeira-library-test-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let docs = temporary.appendingPathComponent("Documents")
        let library = GameLibrary(documents: docs)
        precondition(library.games.isEmpty)
        precondition(library.localURL(for: "C:\\..\\private.exe") == nil)
        precondition(library.localURL(for: "Z:\\outside.exe") == nil)
        precondition(!library.add(title: "Missing", executable: "C:\\missing.exe", arguments: ""))

        let source = temporary.appendingPathComponent("Example Game")
        try fm.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("MZ test executable".utf8).write(to: source.appendingPathComponent("bin/game.exe"))
        try Data("companion DLL".utf8).write(to: source.appendingPathComponent("bin/support.dll"))
        let imported = try GameLibrary.importFolder(source, into: library.driveC)
        precondition(imported.count == 1 && imported[0].hasSuffix("\\bin\\game.exe"))
        let importedURL = library.localURL(for: imported[0])!
        let companion = try Data(contentsOf: importedURL.deletingLastPathComponent().appendingPathComponent("support.dll"))
        precondition(companion == Data("companion DLL".utf8))
        precondition(library.add(title: "Example", executable: imported[0], arguments: "-windowed"))
        let game = library.games.last!
        precondition(library.isInstalled(game))
        library.toggleFavorite(game)
        library.markPlayed(game)
        let reloaded = GameLibrary(documents: docs)
        precondition(reloaded.games.last!.favorite && reloaded.games.last!.lastPlayed != nil)
        precondition(reloaded.games.last!.arguments == "-windowed")
        reloaded.remove(game)
        precondition(!reloaded.games.contains(where: { $0.id == game.id }))
        precondition(fm.fileExists(atPath: importedURL.path))
        do {
            _ = try GameLibrary.importFolder(temporary, into: library.driveC)
            fatalError("Recursive import should have been rejected")
        } catch LibraryImportError.containsDestination { }
        let broken = docs.appendingPathComponent("madeira-library.json")
        try Data("broken JSON".utf8).write(to: broken)
        let corrupted = GameLibrary(documents: docs)
        precondition(corrupted.errorMessage != nil)
        precondition(!corrupted.add(title: "Example", executable: imported[0], arguments: ""))
        let preserved = try Data(contentsOf: broken)
        precondition(preserved == Data("broken JSON".utf8))
        print("Library tests passed: import with dependencies, path bounds, persistence, favorites, history, removal, corrupt-file preservation.")
    }
}
