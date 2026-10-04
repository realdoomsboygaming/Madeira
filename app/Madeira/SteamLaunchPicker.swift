// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// Only eligibility and presentation are decided here. Valve's client receives
/// the original configuration ID and applies its executable, arguments and cwd.
enum SteamLaunchOptions {
    struct Choice: Identifiable, Equatable, Sendable {
        let id: UInt32
        let option: SteamLaunchOption
        let program: String
        var isDefault = false

        var title: String {
            if let text = option.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.range(of: "#[A-Za-z_][A-Za-z0-9_]*", options: .regularExpression) == nil,
               !text.unicodeScalars.contains(where: { $0.value < 32 }) { return text }
            switch option.type.lowercased() {
            case "safemode": return "Safe mode"
            case "multiplayer": return "Multiplayer"
            case "server": return "Server"
            case "editor": return "Editor"
            case "vr", "othervr": return "Virtual reality"
            default: return isDefault ? "Play game" : URL(fileURLWithPath: program).lastPathComponent
            }
        }

        var architecture: String {
            switch option.osarch.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "32": return "32-bit"
            case "64": return "64-bit"
            default: return "32-bit / 64-bit (Steam chooses)"
            }
        }
    }

    enum FallbackReason: String, Sendable {
        case metadataUnavailable = "metadata-unavailable"
        case noUsableOptions = "no-usable-options"

        var message: String {
            switch self {
            case .metadataUnavailable:
                return "Steam's launch metadata could not be loaded. Play will ask Steam to use its default configuration (ID 0). You can retry loading the options."
            case .noUsableOptions:
                return "No launch options matched the installed Windows files and Steam branch. Play will ask Steam to use its default configuration (ID 0). You can retry loading the options."
            }
        }
    }

    struct Snapshot: Equatable, Sendable {
        let choices: [Choice]
        let metadataCount: Int
        let fallbackReason: FallbackReason?
        var defaultID: UInt32 { choices.first?.id ?? 0 }
        func contains(_ id: UInt32) -> Bool {
            fallbackReason != nil ? id == 0 : choices.contains { $0.id == id }
        }
    }

    static func resolve(_ metadata: [SteamLaunchOption]?, installFolder: URL, branch: String) -> Snapshot {
        guard let metadata else {
            return Snapshot(choices: [], metadataCount: 0, fallbackReason: .metadataUnavailable)
        }
        let choices = available(metadata, installFolder: installFolder, branch: branch)
        return Snapshot(choices: choices, metadataCount: metadata.count,
                        fallbackReason: choices.isEmpty ? .noUsableOptions : nil)
    }

    static func available(_ metadata: [SteamLaunchOption], installFolder root: URL,
                          branch: String) -> [Choice] {
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let installedBranch = normalizedBranch.isEmpty ? "public" : normalizedBranch
        var seen = Set<UInt32>()
        var choices: [Choice] = []
        for option in metadata {
            let platforms = option.oslist.lowercased().split { $0 == "," || $0.isWhitespace }
            let architecture = option.osarch.trimmingCharacters(in: .whitespacesAndNewlines)
            let beta = option.betaKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let id = option.optionID, !seen.contains(id),
                  platforms.isEmpty || platforms.contains("windows"),
                  ["", "32", "64"].contains(architecture),
                  beta.isEmpty || beta == installedBranch,
                  let path = SteamDirectStart.relativePath(option.executable), !path.isEmpty,
                  ["exe", "bat", "cmd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                  let program = SteamDirectStart.onDisk(path, in: root, directory: false) else { continue }
            guard let folder = SteamDirectStart.relativePath(option.workingDir),
                  SteamDirectStart.onDisk(folder, in: root, directory: true) != nil else { continue }
            seen.insert(id)
            choices.append(Choice(id: id, option: option, program: program))
        }
        func priority(_ choice: Choice) -> Int {
            if choice.option.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default" { return 0 }
            return choice.id == 0 ? 1 : 2
        }
        choices.sort { priority($0) != priority($1) ? priority($0) < priority($1) : $0.id < $1.id }
        if !choices.isEmpty { choices[0].isDefault = true }
        return choices
    }
}

/// A request and every refresh have separate identities. Cancelling invalidates
/// both even when a metadata provider ignores cooperative task cancellation.
@MainActor final class SteamLaunchPickerModel: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let game: DockGame
        fileprivate let readiness: @MainActor () -> String?
        fileprivate let start: @MainActor (UInt32) -> Void
    }

    @Published private(set) var request: Request?
    @Published private(set) var snapshot: SteamLaunchOptions.Snapshot?
    @Published private(set) var selectedID: UInt32?
    @Published private(set) var loading = false
    @Published private(set) var launchError: String?
    private let load: @MainActor (DockGame) async -> SteamLaunchOptions.Snapshot
    private let log: (String) -> Void
    private var loadTask: Task<Void, Never>?
    private var revision = UUID()

    init(load: @escaping @MainActor (DockGame) async -> SteamLaunchOptions.Snapshot,
         log: @escaping (String) -> Void = { _ in }) {
        self.load = load
        self.log = log
    }

    @discardableResult func begin(_ game: DockGame,
                                 readiness: @escaping @MainActor () -> String? = { nil },
                                 start: @escaping @MainActor (UInt32) -> Void) -> Bool {
        guard request == nil else { return false }
        request = Request(game: game, readiness: readiness, start: start)
        refresh(requestID: request!.id)
        return true
    }

    func refresh(requestID: UUID) {
        guard let pending = request, pending.id == requestID else { return }
        loadTask?.cancel()
        let generation = UUID()
        revision = generation
        loading = true
        snapshot = nil
        selectedID = nil
        launchError = nil
        let loader = load
        loadTask = Task { [weak self] in
            let result = await loader(pending.game)
            guard let self, !Task.isCancelled, self.request?.id == requestID,
                  self.revision == generation else { return }
            self.snapshot = result
            self.selectedID = result.defaultID
            self.loading = false
            self.loadTask = nil
            self.log("[steam-launch] app=\(pending.game.id) metadata-count=\(result.metadataCount) usable-count=\(result.choices.count) fallback=\(result.fallbackReason?.rawValue ?? "none")")
        }
    }

    func choose(_ id: UInt32, requestID: UUID) {
        guard request?.id == requestID, !loading, snapshot?.contains(id) == true else { return }
        selectedID = id
        launchError = nil
    }

    func canPlay(requestID: UUID) -> Bool {
        request?.id == requestID && !loading && selectedID.map { snapshot?.contains($0) == true } == true
    }

    /// Only the explicit Play action may consume a request and call Dock.
    @discardableResult func play(requestID: UUID) -> Bool {
        guard let pending = request, pending.id == requestID, canPlay(requestID: requestID),
              let selectedID else { return false }
        if let reason = pending.readiness() { launchError = reason; return false }
        let fallback = snapshot?.fallbackReason?.rawValue ?? "none"
        cancel(requestID)
        log("[steam-launch] app=\(pending.game.id) selected-id=\(selectedID) fallback=\(fallback)")
        pending.start(selectedID)
        return true
    }

    func cancel(_ requestID: UUID) {
        guard request?.id == requestID else { return }
        revision = UUID()
        loadTask?.cancel()
        loadTask = nil
        request = nil
        snapshot = nil
        selectedID = nil
        loading = false
        launchError = nil
    }
}

// MARK: - App integration

extension SteamLaunchPickerModel {
    static let shared = SteamLaunchPickerModel(load: { game in
        let metadata = await SteamOwnedLibrary.shared.launchOptions(appID: game.id, refresh: true)
        let drive = MadeiraDock.drive
        return await Task.detached(priority: .userInitiated) {
            // Resolve the installation with the same Windows filename semantics
            // used for executables, including containment in the existing drive.
            let path = game.library + "/common/" + game.installDir
            guard let current = MadeiraDock.currentGame(game, drive: drive),
                  MadeiraDock.sameInstallation(game, current),
                  let relative = SteamDirectStart.relativePath(path),
                  let installed = SteamDirectStart.onDisk(relative, in: drive, directory: true) else {
                return SteamLaunchOptions.Snapshot(choices: [], metadataCount: metadata?.count ?? 0,
                    fallbackReason: metadata == nil ? .metadataUnavailable : .noUsableOptions)
            }
            return SteamLaunchOptions.resolve(metadata, installFolder: drive.appendingPathComponent(installed),
                                              branch: game.betaKey)
        }.value
    }, log: { SteamLog.event($0) })
}

struct SteamLaunchPicker: View {
    let request: SteamLaunchPickerModel.Request
    @ObservedObject private var model = SteamLaunchPickerModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.game.name).font(.headline)
                    Text("Choose how Steam starts this game.").foregroundStyle(.secondary)
                }
                if model.loading {
                    HStack(spacing: 12) { ProgressView(); Text("Refreshing Steam launch options…") }
                } else if let reason = model.snapshot?.fallbackReason {
                    Section {
                        Label("Steam default", systemImage: "checkmark.circle.fill").font(.headline)
                        Text(reason.message).foregroundStyle(.secondary)
                        Button("Retry") { model.refresh(requestID: request.id) }
                    }
                } else if let snapshot = model.snapshot {
                    Section {
                        ForEach(snapshot.choices) { choice in
                            Button { model.choose(choice.id, requestID: request.id) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(choice.title).foregroundStyle(.primary)
                                            if choice.isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Text("Executable: \(choice.program)").font(.caption).foregroundStyle(.secondary)
                                        Text("Arguments: \(choice.option.arguments.isEmpty ? "None" : choice.option.arguments)")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(choice.architecture).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedID == choice.id { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                            .accessibilityAddTraits(model.selectedID == choice.id ? .isSelected : [])
                        }
                    } footer: {
                        Text("Options match the installed Windows files and Steam branch. Steam applies the selected configuration when you tap Play.")
                    }
                }
                if let error = model.launchError { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Launch options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel(request.id); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Play") { if model.play(requestID: request.id) { dismiss() } }
                        .disabled(!model.canPlay(requestID: request.id))
                }
            }
            .onDisappear { model.cancel(request.id) }
        }
    }
}
