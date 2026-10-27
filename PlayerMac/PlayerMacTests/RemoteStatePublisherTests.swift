import Foundation
import RemoteProtocol
import Testing

@testable import Kinrox

@Suite("M4.4: state broadcasting", .timeLimit(.minutes(1)))
@MainActor
struct RemoteStatePublisherTests {
    @Test("Seek to last published snapshot resynchronizes remote clock")
    func repeatedSeekSnapshot() {
        var time = 0.0
        var sent: [PlayerState] = []
        let publisher = RemoteStatePublisher(now: { time }, publish: { sent.append($0) })
        defer { publisher.reset() }
        publisher.update(state(0))
        time = 0.4
        publisher.update(state(0.4))
        publisher.update(state(0), immediate: true)
        #expect(sent.map(\.position) == [0, 0])
        time = 0.45
        publisher.update(state(0), immediate: true)
        #expect(sent.map(\.position) == [0, 0, 0])
    }

    @Test("Ticks throttled to 2 Hz, pause/seek immediate, deferred tick replaced by fresh")
    func throttle() async throws {
        var time = 0.0
        var sent: [PlayerState] = []
        let publisher = RemoteStatePublisher(now: { time }, publish: { sent.append($0) })
        publisher.update(state(0))
        for tick in 1...49 {
            time = Double(tick) / 100
            publisher.update(state(time))
        }
        #expect(sent.count == 1)
        time = 0.5
        publisher.update(state(0.5))
        #expect(sent.count == 2)
        time = 0.51
        publisher.update(state(0.51))
        publisher.update(state(0.51, paused: true))
        #expect(sent.count == 3 && sent.last?.paused == true)
        publisher.update(state(10, paused: true), immediate: true)
        #expect(sent.last?.position == 10)
        publisher.reset()
        time = 1
        publisher.update(state(20))
        time = 1.49
        publisher.update(state(21))
        time = 1.5
        try await Task.sleep(for: .milliseconds(30))
        #expect(sent.last?.position == 21)
        publisher.update(state(22))
        publisher.reset()
        let count = sent.count
        try await Task.sleep(for: .milliseconds(520))
        #expect(sent.count == count)
    }

    private func state(_ position: Double, paused: Bool = false) -> PlayerState {
        PlayerState(
            title: "Video", position: position, duration: 100, paused: paused, volume: 0,
            fullscreen: false, hasMedia: true, canNext: false, canPrevious: false)
    }
}
