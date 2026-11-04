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
        manual.append(MusicQueueItem(track: track, origin: .manual))
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
    @discardableResult
    public mutating func move(_ id: UUID, before destination: UUID) -> Bool {
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
