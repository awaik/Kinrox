import AppKit

/// Registering power notifications neither starts playback nor reads credentials.
@MainActor
final class SoloistSleepObserver {
    private var tokens: [NSObjectProtocol] = []

    init(
        sleep: @escaping @MainActor @Sendable () -> Void,
        wake: @escaping @MainActor @Sendable () -> Void
    ) {
        let center = NSWorkspace.shared.notificationCenter
        for (name, action) in [
            (NSWorkspace.willSleepNotification, sleep), (NSWorkspace.didWakeNotification, wake),
        ] {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { action() }
                })
        }
    }

    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
    }

    isolated deinit {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
