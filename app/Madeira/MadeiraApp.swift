import SwiftUI

@main
struct MadeiraApp: App {
    init() {
        // Attempt the memory-limit request before SwiftUI creates the first
        // view. A normally signed process fails harmlessly with EPERM; a
        // jailbreak build can succeed even when image/path detection is
        // incomplete. JIT remains gated inside the C helper.
        madeira_jb_initialize()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
