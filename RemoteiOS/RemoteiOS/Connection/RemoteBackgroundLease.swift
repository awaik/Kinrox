import UIKit

/// Grants bye and forced closure brief time before app suspension.
@MainActor
final class RemoteBackgroundLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init(expired: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Remote shutdown") {
            MainActor.assumeIsolated { expired() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
