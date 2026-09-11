// Simulator-only host for the production library and settings views. It never
// links the Wine/FEX native runtime or starts JIT.
import SwiftUI

@main
struct LibraryPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            MadeiraPreviewScreen(settings: ProcessInfo.processInfo.arguments.contains("--settings"))
        }
    }
}
