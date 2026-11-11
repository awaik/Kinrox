import SwiftUI

@main
struct KinroxRemoteApp: App {
    init() {
        // Registers the Lock Screen button handler before any intent runs.
        _ = RemoteAppHost.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
