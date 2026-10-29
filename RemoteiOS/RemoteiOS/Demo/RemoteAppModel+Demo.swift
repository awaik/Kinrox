import Foundation
import RemoteProtocol

extension RemoteAppModel {
    func syncDemo() {
        guard let demo else { return }
        players = demo.players
        let sample = demo.state
        state = PlayerState(
            title: sample.title, position: sample.position(at: Date()),
            duration: sample.duration, paused: sample.paused, volume: sample.volume,
            fullscreen: sample.fullscreen, hasMedia: sample.hasMedia,
            canNext: demo.canNext, canPrevious: demo.canPrevious, screensaver: sample.screensaver)
        receivedAt = scheduler.now
        frozenPosition = state.position
        hasState = true
        recents = demo.recents.map {
            RecentItem(id: $0.id, title: $0.title, duration: $0.duration, available: $0.available)
        }
        discoveryStatus = .ready
    }
    func submitDemoPIN(_ pin: String) {
        guard let demo, let player = demo.players.first(where: { $0.id == selected?.id }) else {
            return
        }
        switch demo.submit(code: pin, for: player) {
        case .paired:
            connectionState = .connected
            screen = .remote
            syncDemo()
        case .wrongCode(let left):
            pairingMessage = L10n.format("Incorrect code, attempts remaining: %@", left.formatted())
            connectionState = .awaitingPIN
            pairingRevision += 1
        case .locked:
            pairingMessage = L10n.text("No attempts remaining. Request a new code.")
            connectionState = .failed
        }
    }
    func performDemo(_ command: Command) {
        guard let demo else { return }
        switch command {
        case .togglePause: demo.togglePause()
        case .setPaused(let value): if demo.state.paused != value { demo.togglePause() }
        case .seekRelative(let value): demo.seek(by: value)
        case .seekAbsolute(let value): demo.seek(to: value)
        case .setVolume(let value): demo.setVolume(value)
        case .next: demo.next()
        case .previous: demo.previous()
        case .openRecent(let id):
            if let item = demo.recents.first(where: { $0.id == id }) { demo.open(item) }
        case .toggleFullscreen: demo.toggleFullscreen()
        case .setScreensaver(let value): demo.setScreensaver(value)
        case .setFullscreen(let value):
            if demo.state.fullscreen != value { demo.toggleFullscreen() }
        }
        syncDemo()
    }
}
