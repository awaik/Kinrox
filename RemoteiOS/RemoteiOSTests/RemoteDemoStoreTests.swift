import Foundation
import Testing

@testable import RemoteiOS

/// Controlled clock to verify position extrapolation.
@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite("Remote on Demo Data")
@MainActor
struct RemoteDemoStoreTests {
    private func makeStore() -> (RemoteDemoStore, Clock) {
        let clock = Clock()
        return (RemoteDemoStore(now: { clock.now }), clock)
    }

    @Test("Position moves between snapshots and halts on pause")
    func extrapolation() {
        let (store, clock) = makeStore()
        let start = store.state.position
        clock.now += 2.5
        #expect(store.state.position(at: clock.now) == start + 2.5)
        store.togglePause()
        clock.now += 10
        #expect(store.state.position(at: clock.now) == start + 2.5)
    }

    @Test("Seek and volume are constrained to valid bounds")
    func clamping() {
        let (store, _) = makeStore()
        store.seek(to: -5)
        #expect(store.state.position == 0)
        store.seek(by: 1_000_000)
        #expect(store.state.position == store.state.duration)
        store.setVolume(140)
        #expect(store.state.volume == 100)
        store.setVolume(.nan)
        #expect(store.state.volume == 100)
    }

    @Test("Three invalid codes lock pairing until a new request")
    func pairingAttempts() {
        let (store, _) = makeStore()
        let mac = store.players[1]
        store.beginPairing()
        #expect(store.submit(code: "000000", for: mac) == .wrongCode(attemptsLeft: 2))
        #expect(store.submit(code: "111111", for: mac) == .wrongCode(attemptsLeft: 1))
        #expect(store.submit(code: "222222", for: mac) == .locked)
        #expect(store.submit(code: RemoteDemoStore.demoCode, for: mac) == .locked)
        store.beginPairing()
        #expect(store.submit(code: RemoteDemoStore.demoCode, for: mac) == .paired)
        #expect(store.players[1].status == .paired)
        store.forget(store.players[1])
        #expect(store.players[1].status == .new)
    }

    @Test("Unavailable file does not open; adjacent files switch")
    func recentsAndNavigation() throws {
        let (store, _) = makeStore()
        let missing = try #require(store.recents.first { !$0.available })
        #expect(!store.open(missing))
        #expect(!store.canPrevious && store.canNext)
        store.next()
        #expect(store.state.title == store.recents[1].title)
        #expect(store.state.position == 0 && !store.state.paused)
        store.previous()
        #expect(store.state.title == store.recents[0].title)
    }
}
