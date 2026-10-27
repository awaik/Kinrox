import Foundation
import Observation

/// Mac in Players list.
struct MacPlayer: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable { case paired, new, unavailable }

    let id: UUID
    var name: String
    var status: Status
    var detail: String
}

/// Recent file on remote: id, title, and duration only.
struct RemoteRecent: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var duration: Double
    var available: Bool
}

/// Protocol PlayerState snapshot with receipt timestamp.
/// Between broadcasts remote interpolates position.
struct RemotePlaybackState: Equatable, Sendable {
    var title: String
    var position: Double
    var duration: Double
    var paused: Bool
    var volume: Double
    var fullscreen: Bool
    var hasMedia: Bool
    var receivedAt: Date

    func position(at date: Date) -> Double {
        guard !paused, hasMedia else { return position }
        return min(duration, position + max(0, date.timeIntervalSince(receivedAt)))
    }
}

enum PairingResult: Equatable, Sendable {
    case paired
    case wrongCode(attemptsLeft: Int)
    case locked
}

/// Remote on demo data: screens function without network.
/// Public methods mirror protocol commands for future data source replacement.
@MainActor @Observable
final class RemoteDemoStore {
    static let demoCode = "482913"
    static let maxAttempts = 3

    var players: [MacPlayer]
    private(set) var state: RemotePlaybackState
    private(set) var recents: [RemoteRecent]
    private(set) var attemptsLeft = RemoteDemoStore.maxAttempts
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        players = [
            MacPlayer(
                id: UUID(), name: "MacBook Pro", status: .paired,
                detail: L10n.text("Paired · playing")
            ),
            MacPlayer(
                id: UUID(), name: "Mac mini - Living Room", status: .new,
                detail: L10n.text("New · code required")),
            MacPlayer(
                id: UUID(), name: "iMac Studio", status: .unavailable,
                detail: L10n.text("Unavailable")),
        ]
        recents = [
            RemoteRecent(id: UUID(), title: "Ember Dusk.mkv", duration: 7083, available: true),
            RemoteRecent(
                id: UUID(), title: "Blue Hour — S02E05.mkv", duration: 2832, available: true),
            RemoteRecent(
                id: UUID(), title: "Blue Hour — S02E04.mkv", duration: 2730, available: true),
            RemoteRecent(id: UUID(), title: "Desert Noon.mp4", duration: 8497, available: true),
            RemoteRecent(id: UUID(), title: "Night Train.mov", duration: 5530, available: false),
        ]
        state = RemotePlaybackState(
            title: "Ember Dusk.mkv", position: 2535, duration: 7083, paused: false, volume: 70,
            fullscreen: true, hasMedia: true, receivedAt: now())
    }

    // MARK: Pairing

    func beginPairing() { attemptsLeft = Self.maxAttempts }

    func submit(code: String, for player: MacPlayer) -> PairingResult {
        guard attemptsLeft > 0 else { return .locked }
        guard code == Self.demoCode else {
            attemptsLeft -= 1
            return attemptsLeft > 0 ? .wrongCode(attemptsLeft: attemptsLeft) : .locked
        }
        update(player.id) {
            $0.status = .paired
            $0.detail = L10n.text("Paired")
        }
        return .paired
    }

    func forget(_ player: MacPlayer) {
        update(player.id) {
            $0.status = .new
            $0.detail = L10n.text("New · code required")
        }
    }

    // MARK: Commands (AGENTS.md 6.3)

    var canNext: Bool { currentIndex.map { $0 + 1 < playable.count } ?? false }
    var canPrevious: Bool { currentIndex.map { $0 > 0 } ?? false }

    func togglePause() { mutate { $0.paused.toggle() } }

    func seek(by seconds: Double) {
        mutate { $0.position = min($0.duration, max(0, $0.position + seconds)) }
    }

    func seek(to seconds: Double) {
        mutate { $0.position = min($0.duration, max(0, seconds)) }
    }

    func setVolume(_ volume: Double) {
        guard volume.isFinite else { return }
        mutate { $0.volume = min(100, max(0, volume)) }
    }

    func toggleFullscreen() { mutate { $0.fullscreen.toggle() } }

    func next() {
        guard let index = currentIndex, index + 1 < playable.count else { return }
        play(playable[index + 1])
    }

    func previous() {
        guard let index = currentIndex, index > 0 else { return }
        play(playable[index - 1])
    }

    /// Open from recents; unavailable file cannot be opened (`itemNotFound`).
    @discardableResult
    func open(_ item: RemoteRecent) -> Bool {
        guard item.available else { return false }
        play(item)
        return true
    }

    // MARK: Internal

    private var playable: [RemoteRecent] { recents.filter(\.available) }
    private var currentIndex: Int? { playable.firstIndex { $0.title == state.title } }

    private func play(_ item: RemoteRecent) {
        mutate {
            $0.title = item.title
            $0.duration = item.duration
            $0.position = 0
            $0.paused = false
            $0.hasMedia = true
        }
    }

    /// Applies command to extrapolated position as Mac would.
    private func mutate(_ change: (inout RemotePlaybackState) -> Void) {
        let date = now()
        var next = state
        next.position = state.position(at: date)
        next.receivedAt = date
        change(&next)
        state = next
    }

    private func update(_ id: UUID, _ change: (inout MacPlayer) -> Void) {
        guard let index = players.firstIndex(where: { $0.id == id }) else { return }
        change(&players[index])
    }
}
