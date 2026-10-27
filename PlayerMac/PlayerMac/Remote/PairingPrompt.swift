import Foundation
import Observation

/// Remote pairing prompt: Mac displays code over video.
struct PairingPrompt: Equatable, Sendable {
    static let lifetime: TimeInterval = 120

    let deviceName: String
    let code: String
    let expiresAt: Date

    func remaining(at date: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(date)) }
}

/// PIN and duration set by server; timeout closes transport via monotonic clock.
@MainActor @Observable
final class PairingCenter {
    private(set) var prompt: PairingPrompt?
    @ObservationIgnored var onDecline: (() -> Void)?

    func show(_ prompt: PairingPrompt) { self.prompt = prompt }

    func dismiss() {
        prompt = nil
        onDecline = nil
    }
    func decline() { onDecline?() }
}
