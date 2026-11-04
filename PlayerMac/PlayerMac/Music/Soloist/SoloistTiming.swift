import Foundation
import OSLog

/// Explicit local diagnostics: fixed stage names and durations only, never playback payloads.
enum SoloistTiming {
    enum Stage: String {
        case verification, credentialRead, spawnToSocket, stop, load, socketToPlayback
    }
    private static let enabled =
        ProcessInfo.processInfo.environment["KINROX_SOLOIST_TIMING"] == "1"
    private static let logger = Logger(subsystem: "app.kinrox.player", category: "SoloistTiming")

    static func record(_ stage: Stage, since start: ContinuousClock.Instant) {
        guard enabled else { return }
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        logger.notice("\(stage.rawValue, privacy: .public) \(milliseconds, privacy: .public) ms")
    }
}
