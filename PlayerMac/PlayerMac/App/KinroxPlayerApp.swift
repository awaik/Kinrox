import SwiftUI

@main
struct KinroxPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            if let remote = delegate.session.remote { RemoteSettingsView(remote: remote) }
        }
        .commands { PlayerCommands(delegate: delegate) }
    }
}
