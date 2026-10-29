import Foundation
import Observation

/// One hint per activation. Pointer activity deliberately has no effect on this timer.
@MainActor @Observable
final class ScreensaverPresentation {
    static let hintDuration: Duration = .seconds(3)
    private(set) var showsHint = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        stop()
        showsHint = true
        task = Task { [weak self] in
            do { try await Task.sleep(for: Self.hintDuration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.showsHint = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        showsHint = false
    }

    deinit { task?.cancel() }
}
