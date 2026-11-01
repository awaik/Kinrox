import Foundation
import Testing

@testable import MusicCore

struct MusicQueueTests {
    let tracks = Array(MusicDemo.catalog.tracks.prefix(5))

    @Test func orderingNextPreviousAndEnd() {
        var queue = MusicQueue()
        queue.start(tracks, at: 1)
        queue.add(tracks[4])
        #expect(
            queue.items.map(\.track.id)
                == [tracks[1], tracks[4], tracks[2], tracks[3], tracks[4]].map(\.id))
        #expect(queue.next()?.track == tracks[4])
        #expect(queue.previous()?.track == tracks[1])
        #expect(queue.next()?.track == tracks[4])
        #expect(queue.next()?.track == tracks[2])
        #expect(queue.next()?.track == tracks[3])
        #expect(queue.next()?.track == tracks[4])
        #expect(queue.next() == nil)
        #expect(queue.current?.track == tracks[4])
    }

    @Test func movesAndRemovalUseOccurrenceIdentity() throws {
        var queue = MusicQueue()
        queue.start(tracks)
        queue.add(tracks[1])
        queue.add(tracks[1])
        let first = try #require(queue.manual.first)
        let duplicate = try #require(queue.manual.last)
        #expect(first.id != duplicate.id)
        let moved = queue.move(duplicate.id, before: first.id)
        #expect(moved)
        #expect(queue.manual.first?.id == duplicate.id)
        let removed = queue.remove(first.id)
        #expect(removed)
        #expect(queue.manual.count == 1)
        #expect(queue.source.contains { $0.track.id == tracks[1].id })
        let currentID = try #require(queue.current?.id)
        let removedCurrent = queue.remove(currentID)
        #expect(!removedCurrent)
        let removedMissing = queue.remove(UUID())
        #expect(!removedMissing)
        let movedToSelf = queue.move(duplicate.id, before: duplicate.id)
        #expect(!movedToSelf)
    }

    @Test func draggingAcrossSectionsKeepsQueueOrder() throws {
        var queue = MusicQueue()
        queue.start(tracks)
        queue.add(tracks[0])
        let manual = try #require(queue.manual.first)
        let source = try #require(queue.source.last)
        let moved = queue.move(source.id, before: manual.id)
        #expect(moved)
        #expect(queue.manual.map(\.id) == [source.id, manual.id])
        #expect(queue.source.count == tracks.count - 2)
    }

    @Test func shufflePreservesCurrentAndManualAndCanRestoreSourceOrder() {
        var queue = MusicQueue()
        queue.start(tracks)
        queue.add(tracks[0])
        let original = queue
        var random = SystemRandomNumberGenerator()
        queue.setShuffle(true, using: &random)
        #expect(queue.current == original.current)
        #expect(queue.manual == original.manual)
        #expect(Set(queue.source.map(\.id)) == Set(original.source.map(\.id)))
        queue.setShuffle(false, using: &random)
        #expect(queue.source == original.source)
    }

    @Test func repeatOneOnlyAtEOFAndRepeatAllSkipsRemovedItems() throws {
        var queue = MusicQueue()
        queue.start(tracks)
        queue.repeatMode = .one
        #expect(queue.next(automatically: true)?.track == tracks[0])
        #expect(queue.next()?.track == tracks[1])
        let removed = try #require(queue.source.last)
        queue.remove(removed.id)
        queue.repeatMode = .all
        _ = queue.next()
        _ = queue.next()
        #expect(queue.next()?.track == tracks[0])
        #expect(!queue.source.contains { $0.id == removed.id })
    }

    @Test func shuffledStartIncludesFirstTrackAndPreservesEveryOccurrenceAndSourceOrder() {
        let tracks = tracks + [tracks[0]]
        var random = SeededQueueRandom()
        var expectedRandom = SeededQueueRandom()
        let expected = Array(tracks.indices).shuffled(using: &expectedRandom)
        #expect(expected.first != 0)
        var queue = MusicQueue()
        queue.startShuffled(tracks, using: &random)
        #expect(queue.shuffled)
        #expect(queue.items.map(\.sourceOrder) == expected)
        #expect(queue.items.map(\.track.id).sorted() == tracks.map(\.id).sorted())
        #expect(Set(queue.items.map(\.id)).count == tracks.count)
        #expect(queue.history.isEmpty)
        #expect(queue.previous() == nil)
        let current = queue.current
        queue.setShuffle(false, using: &random)
        #expect(queue.current == current)
        #expect(
            queue.source.map(\.sourceOrder) == tracks.indices.filter { $0 != current?.sourceOrder })
        let original = queue
        queue.startShuffled([], using: &random)
        #expect(queue == original)
    }

    @Test func emptyAndInvalidStartsAreSafe() {
        var queue = MusicQueue()
        queue.start([])
        queue.start(tracks, at: -1)
        #expect(queue.items.isEmpty)
        #expect(queue.next() == nil)
        #expect(queue.previous() == nil)
        queue.repeatMode = .all
        #expect(queue.next() == nil)
    }

    @Test func repeatCyclesHaveDistinctOccurrenceIDsAndRemainEditable() throws {
        var queue = MusicQueue()
        queue.start(Array(tracks.prefix(2)))
        queue.repeatMode = .all
        _ = queue.next()
        _ = queue.next()
        _ = queue.previous()
        #expect(Set(queue.items.map(\.id)).count == queue.items.count)
        _ = queue.next()
        let pending = try #require(queue.source.first)
        queue.remove(pending.id)
        _ = queue.next()
        #expect(queue.current?.track == tracks[0])
        #expect(queue.context.count == 1)
    }
}

private struct SeededQueueRandom: RandomNumberGenerator {
    var state: UInt64 = 1
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
