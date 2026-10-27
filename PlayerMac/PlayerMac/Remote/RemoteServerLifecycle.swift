import AppKit
import Network

@MainActor
final class RemoteServerLifecycle {
    private let monitor = NWPathMonitor()
    private var observations: [NSObjectProtocol] = []
    private var restart: Task<Void, Never>?
    private var hasPath = false
    private var stopped = false

    init(
        networkChanged: @escaping @MainActor @Sendable () -> Void,
        sleep: @escaping @MainActor @Sendable () -> Void,
        wake: @escaping @MainActor @Sendable () -> Void
    ) {
        monitor.pathUpdateHandler = { [weak self] _ in
            // NWPathMonitor below runs on main only.
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                guard self.hasPath else {
                    self.hasPath = true
                    return
                }
                self.restart?.cancel()
                self.restart = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard let self, !self.stopped else { return }
                    networkChanged()
                }
            }
        }
        monitor.start(queue: .main)
        let center = NSWorkspace.shared.notificationCenter
        for (name, action) in [
            (NSWorkspace.willSleepNotification, sleep),
            (NSWorkspace.didWakeNotification, wake),
        ] {
            observations.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { action() }
                })
        }
    }

    func stop() {
        stopped = true
        monitor.cancel()
        restart?.cancel()
        for token in observations { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observations.removeAll()
    }
}
