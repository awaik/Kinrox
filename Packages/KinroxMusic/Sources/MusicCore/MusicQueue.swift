import Foundation

public enum MusicRepeat: String, Codable, CaseIterable, Sendable {
    case off, all, one
}

/// An occurrence has its own identity: duplicate tracks can be moved independently.
public struct MusicQueueItem: Identifiable, Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case manual, source }
    public let id: UUID
    public let track: MusicTrack
    public var origin: Origin
    public let sourceOrder: Int

    public init(track: MusicTrack, origin: Origin, sourceOrder: Int = -1, id: UUID = UUID()) {
        self.id = id
        self.track = track
        self.origin = origin
        self.sourceOrder = sourceOrder
    }
}

public struct MusicQueue: Equatable, Sendable {
    public private(set) var current: MusicQueueItem?
    public private(set) var manual: [MusicQueueItem] = []
    public private(set) var source: [MusicQueueItem] = []
    public private(set) var history: [MusicQueueItem] = []
    public private(set) var context: [MusicQueueItem] = []
    public private(set) var shuffled = false
    public var repeatMode = MusicRepeat.off

    public init() {}

    public var upcoming: [MusicQueueItem] { manual + source }
    public var items: [MusicQueueItem] { (current.map { [$0] } ?? []) + upcoming }

    public mutating func start(_ tracks: [MusicTrack], at index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        context = tracks.enumerated().map {
            MusicQueueItem(track: $0.element, origin: .source, sourceOrder: $0.offset)
        }
        current = context[index]
        history = Array(context.prefix(index))
        source = Array(context.dropFirst(index + 1))
        manual = []
        shuffled = false
    }

    /// Shuffle the entire collection, including the first occurrence, without
    /// treating earlier source positions as already played.
    public mutating func startShuffled<R: RandomNumberGenerator>(
        _ tracks: [MusicTrack], using random: inout R
    ) {
        guard !tracks.isEmpty else { return }
        start(tracks)
        source = context.shuffled(using: &random)
        current = source.removeFirst()
        shuffled = true
    }

    public mutating func add(_ track: MusicTrack) {
        guard track.isPlayable != false else { return }
        manual.append(MusicQueueItem(track: track, origin: .manual))
    }

    public mutating func add(_ tracks: [MusicTrack]) {
        _ = insert(tracks, before: nil)
    }

    /// Inserts one or more tracks (such as an expanded album or playlist) before a target
    /// queue item, or appends them to the manual queue when `destination` is nil.
    @discardableResult
    public mutating func insert(
        _ tracks: [MusicTrack], before destination: UUID? = nil
    ) -> [UUID] {
        let playable = tracks.filter { $0.isPlayable != false }
        guard !playable.isEmpty else { return [] }
        if let destination, let target = upcoming.first(where: { $0.id == destination }) {
            let items = playable.map { MusicQueueItem(track: $0, origin: target.origin) }
            if target.origin == .manual {
                let index = manual.firstIndex { $0.id == destination } ?? manual.count
                manual.insert(contentsOf: items, at: index)
            } else {
                let index = source.firstIndex { $0.id == destination } ?? source.count
                source.insert(contentsOf: items, at: index)
            }
            return items.map(\.id)
        }
        let items = playable.map { MusicQueueItem(track: $0, origin: .manual) }
        manual.append(contentsOf: items)
        return items.map(\.id)
    }

    public mutating func appendSource(_ tracks: [MusicTrack]) {
        let start = (context.map(\.sourceOrder).max() ?? -1) + 1
        let items = tracks.filter { $0.isPlayable != false }.enumerated().map {
            MusicQueueItem(track: $0.element, origin: .source, sourceOrder: start + $0.offset)
        }
        source.append(contentsOf: items)
        context.append(contentsOf: items)
    }

    /// Replaces pending source occurrences, keeping the current item, manual items and history.
    public mutating func replaceSource(_ tracks: [MusicTrack]) {
        // Repeat All reuses source orders; Previous can put a played order back in source.
        let kept = Set(((current.map { [$0] } ?? []) + history).map(\.sourceOrder))
        let replaced = Set(source.map(\.sourceOrder)).subtracting(kept)
        context.removeAll { replaced.contains($0.sourceOrder) }
        source = []
        appendSource(tracks)
    }

    public mutating func clearManual() {
        for id in manual.map(\.id) {
            _ = remove(id)
        }
    }

    @discardableResult
    public mutating func moveOffset(_ id: UUID, by delta: Int) -> Bool {
        guard delta != 0 else { return false }
        let items = upcoming
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let targetIndex = min(max(0, index + delta), items.count - 1)
        guard targetIndex != index else { return false }
        if delta < 0 {
            return move(id, before: items[targetIndex].id)
        }
        if targetIndex + 1 < items.count {
            return move(id, before: items[targetIndex + 1].id)
        }
        return move(id, before: nil)
    }

    /// Current playback is kept separate; removal only affects pending entries.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let removed = upcoming.first(where: { $0.id == id }) else { return false }
        manual.removeAll { $0.id == id }
        source.removeAll { $0.id == id }
        if removed.sourceOrder >= 0 { context.removeAll { $0.sourceOrder == removed.sourceOrder } }
        return true
    }

    /// Dropping into a section adopts that section, preserving manual-before-source order.
    /// Passing `nil` for `destination` moves the item to the tail of the upcoming queue.
    @discardableResult
    public mutating func move(_ id: UUID, before destination: UUID? = nil) -> Bool {
        guard let destination else {
            guard var item = upcoming.first(where: { $0.id == id }) else { return false }
            manual.removeAll { $0.id == id }
            source.removeAll { $0.id == id }
            if !source.isEmpty {
                item.origin = .source
                source.append(item)
            } else {
                item.origin = .manual
                manual.append(item)
            }
            return true
        }
        guard id != destination, var item = upcoming.first(where: { $0.id == id }),
            let target = upcoming.first(where: { $0.id == destination })
        else { return false }
        manual.removeAll { $0.id == id }
        source.removeAll { $0.id == id }
        item.origin = target.origin
        if target.origin == .manual {
            manual.insert(item, at: manual.firstIndex { $0.id == destination } ?? manual.count)
        } else {
            source.insert(item, at: source.firstIndex { $0.id == destination } ?? source.count)
        }
        return true
    }

    public mutating func setShuffle<R: RandomNumberGenerator>(_ value: Bool, using random: inout R)
    {
        guard value != shuffled else { return }
        shuffled = value
        if value {
            source.shuffle(using: &random)
        } else {
            source.sort { $0.sourceOrder < $1.sourceOrder }
        }
    }

    /// Repeat-one applies at EOF, not to an explicit Next command.
    @discardableResult
    public mutating func next(automatically: Bool = false) -> MusicQueueItem? {
        var random = SystemRandomNumberGenerator()
        return next(automatically: automatically, using: &random)
    }

    /// Preserve the caller's random stream when Repeat All reshuffles a new cycle.
    @discardableResult
    public mutating func next<R: RandomNumberGenerator>(
        automatically: Bool = false, using random: inout R
    ) -> MusicQueueItem? {
        if automatically, repeatMode == .one { return current }
        if manual.isEmpty && source.isEmpty {
            guard repeatMode == .all, !context.isEmpty else { return nil }
            source = context.map {
                MusicQueueItem(track: $0.track, origin: .source, sourceOrder: $0.sourceOrder)
            }
            if shuffled { source.shuffle(using: &random) }
        }
        if let current { history.append(current) }
        current = !manual.isEmpty ? manual.removeFirst() : source.removeFirst()
        return current
    }

    @discardableResult
    public mutating func previous() -> MusicQueueItem? {
        guard let previous = history.popLast() else { return nil }
        if let current {
            if current.origin == .manual {
                manual.insert(current, at: 0)
            } else {
                source.insert(current, at: 0)
            }
        }
        // Crossing back from a manual item must not put source ahead of it on Next.
        current = previous
        return previous
    }

    public mutating func clear() { self = MusicQueue() }
}
