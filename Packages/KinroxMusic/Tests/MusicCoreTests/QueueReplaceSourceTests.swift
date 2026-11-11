import Foundation
import MusicCore
import Testing

@Suite("Queue source replacement")
struct QueueReplaceSourceTests {
    private func track(_ id: String) -> MusicTrack {
        MusicTrack(
            id: id, uri: "spotify:track:\(id)", title: id, artists: [], albumID: "",
            albumTitle: "", duration: 60)
    }

    @Test func replacingSourceKeepsCurrentManualAndHistory() {
        var queue = MusicQueue()
        queue.start(["a", "b", "c", "d"].map(track), at: 1)
        queue.add(track("m"))
        queue.replaceSource(["x", "y"].map(track))
        #expect(queue.current?.track.id == "b")
        #expect(queue.history.map(\.track.id) == ["a"])
        #expect(queue.manual.map(\.track.id) == ["m"])
        #expect(queue.source.map(\.track.id) == ["x", "y"])
        queue.next()
        queue.next()
        queue.next()
        #expect(queue.current?.track.id == "y")
        queue.repeatMode = .all
        queue.next()
        // A repeat cycle replays the kept context plus the replacement, not the replaced tracks.
        #expect(
            ([queue.current] + queue.source).compactMap { $0?.track.id }.sorted()
                == ["a", "b", "x", "y"])
    }
    @Test func replacementAfterRepeatAndPreviousKeepsPlayedContext() {
        var queue = MusicQueue()
        queue.start(["a", "b", "c"].map(track))
        queue.repeatMode = .all
        queue.next()
        queue.next()
        queue.next()  // New cycle: a current, b and c pending.
        queue.previous()  // c current; a, b, c pending with reused source orders.
        let current = queue.current
        let history = queue.history
        queue.replaceSource([track("x")])
        #expect(queue.current == current && queue.history == history)
        #expect(queue.context.map(\.track.id) == ["a", "b", "c", "x"])
        queue.next()
        queue.next()
        #expect(
            ([queue.current] + queue.source).compactMap { $0?.track.id } == ["a", "b", "c", "x"])
    }

}
