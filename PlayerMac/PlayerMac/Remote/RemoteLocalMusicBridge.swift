import Foundation
import MusicCore
import RemoteProtocol

/// Maps LocalAudioViewModel into additive v1 `MusicState(origin: .local)` and opaque queue pages.
@MainActor
final class RemoteLocalMusicBridge {
    let player: LocalAudioViewModel
    let ids: RemoteLibraryIDs
    let serverName: String
    var changed: (() -> Void)?

    private let libraryRevision: () -> UUID
    private let isScreensaverEngaged: () -> Bool
    private var observation: UUID?
    private var lastQueue: MusicQueue
    private(set) var queueRevision = UUID()

    init(
        player: LocalAudioViewModel, ids: RemoteLibraryIDs, serverName: String,
        libraryRevision: @escaping () -> UUID, isScreensaverEngaged: @escaping () -> Bool
    ) {
        self.player = player
        self.ids = ids
        self.serverName = serverName
        self.libraryRevision = libraryRevision
        self.isScreensaverEngaged = isScreensaverEngaged
        lastQueue = player.queue
        observation = player.observePlayback { [weak self] _ in self?.update() }
    }

    func disconnect() {
        if let observation { player.removePlaybackObserver(observation) }
        observation = nil
    }

    func update() {
        if lastQueue != player.queue {
            lastQueue = player.queue
            queueRevision = UUID()
        }
        changed?()
    }

    var state: MusicState {
        let queue = player.queue
        var disallowed: Set<String> = ["like", "similar"]
        if !player.canNext { disallowed.insert("skipping_next") }
        if !player.canPrevious { disallowed.insert("skipping_prev") }
        if isScreensaverEngaged() {
            disallowed.formUnion(["resuming", "seeking", "skipping_next", "skipping_prev"])
        }
        return MusicState(
            track: queue.current.map { remoteTrack($0.track) },
            nextTrack: queue.upcoming.first.map { remoteTrack($0.track) },
            liked: false,
            shuffle: queue.shuffled,
            repeatMode: RemoteMusicRepeat(rawValue: queue.repeatMode.rawValue) ?? .off,
            queueCount: min(100_000, queue.items.count),
            queueRevision: queueRevision,
            libraryRevision: libraryRevision(),
            outputName: RemoteLibraryBridge.truncateUTF8(serverName, maxBytes: 512),
            status: nil,
            disallowedActions: disallowed.sorted(),
            favoriteFeedback: nil,
            positionAge: 0,
            volumeKnown: true,
            similar: nil,
            origin: .local)
    }

    func snapshot(fullscreen: Bool, screensaver: Screensaver) -> PlayerState {
        let track = player.currentTrack
        let hasMedia = track != nil
        return PlayerState(
            title: track.map { RemoteLibraryBridge.truncateUTF8($0.title, maxBytes: 512) } ?? "",
            position: hasMedia && player.position.isFinite ? max(0, player.position) : 0,
            duration: hasMedia && player.duration.isFinite ? max(0, player.duration) : 0,
            paused: !hasMedia || player.paused,
            volume: player.volume,
            fullscreen: fullscreen,
            hasMedia: hasMedia,
            canNext: player.canNext,
            canPrevious: player.canPrevious,
            screensaver: screensaver,
            source: .music,
            music: state)
    }

    func queuePage(_ request: QueueRequest, replyTo: UUID) -> Message {
        let all = player.queue.items
        let total = min(all.count, 100_000)
        let offset =
            request.revision == nil || request.revision == queueRevision
            ? min(request.offset, total) : 0
        var count = min(20, total - offset)
        while true {
            let items = all.dropFirst(offset).prefix(count).map { item in
                RemoteQueueItem(
                    id: item.id,
                    section: item.id == player.queue.current?.id
                        ? .current : item.origin == .manual ? .manual : .source,
                    track: remoteTrack(item.track),
                    liked: false)
            }
            let end = offset + items.count
            let message = Message.queue(
                .init(),
                .init(
                    replyTo: replyTo, revision: queueRevision, offset: offset,
                    total: total, nextOffset: end < total ? end : nil, items: items))
            if let bytes = try? Codec.encode(message),
                bytes.count <= SecureChannel.maxPlaintextBytes
            {
                return message
            }
            guard count > 1 else {
                return .error(
                    .init(),
                    .init(
                        replyTo: replyTo, code: .internal, message: "Queue item exceeds frame size."
                    ))
            }
            count /= 2
        }
    }

    func execute(_ command: Command) -> ProtocolError.Code? {
        let accepted: Bool
        switch command {
        case .togglePause: accepted = player.togglePause()
        case .setPaused(let paused): accepted = player.setPaused(paused)
        case .seekRelative(let seconds): accepted = player.seek(player.position + seconds)
        case .seekAbsolute(let seconds): accepted = player.seek(seconds)
        case .setVolume(let volume): accepted = player.setVolume(volume)
        case .next:
            guard player.canNext else { return .itemNotFound }
            accepted = player.next()
        case .previous:
            guard player.canPrevious else { return .itemNotFound }
            accepted = player.previous()
        case .setShuffle(let value):
            player.setShuffle(value)
            return nil
        case .setRepeat(let mode):
            player.setRepeat(MusicRepeat(rawValue: mode.rawValue) ?? .off)
            return nil
        case .queueMove(let id, let target):
            return player.moveQueue(id, before: target) ? nil : .itemNotFound
        case .queueRemove(let id):
            return player.removeFromQueue(id) ? nil : .itemNotFound
        case .setTrackLiked, .setPlaylistMembership, .setArtistFollowed, .createPlaylist,
            .setSimilar, .setNotInterested:
            return .invalidPayload
        default:
            return .unknownMessage
        }
        return accepted ? nil : .internal
    }

    func remoteTrack(_ value: MusicTrack) -> RemoteMusicTrack {
        let local = player.track(for: value.id)
        let opaqueID = ids.id(kind: .track, key: value.id)
        let albumKey = local?.file.albumKey ?? (value.albumID.isEmpty ? nil : value.albumID)
        let opaqueAlbumID = albumKey.map { ids.id(kind: .album, key: $0) }
        let year =
            RemoteLibraryBridge.validYear(local?.file.audio?.year).map(String.init)
            ?? local?.metadata?.year ?? ""
        let badge = local.map(LocalAudioViewModel.formatBadge(for:))
        let artists: [String]
        if let artist = local?.artist, !artist.isEmpty {
            artists = [RemoteLibraryBridge.truncateUTF8(artist, maxBytes: 128)]
        } else {
            artists = value.artists.prefix(100).map {
                RemoteLibraryBridge.truncateUTF8(
                    $0.name, maxBytes: min(128, 3000 / max(1, value.artists.count)))
            }
        }
        let tagDuration = local?.file.audio?.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let liveDuration =
            value.id == player.queue.current?.track.id && player.duration.isFinite
                && player.duration > 0 ? player.duration : nil
        let rawDuration = tagDuration ?? liveDuration ?? value.duration
        return RemoteMusicTrack(
            id: opaqueID,
            title: RemoteLibraryBridge.truncateUTF8(local?.title ?? value.title, maxBytes: 512),
            artists: artists,
            album: RemoteLibraryBridge.truncateUTF8(
                local?.album ?? value.albumTitle, maxBytes: 512),
            year: RemoteLibraryBridge.truncateUTF8(year, maxBytes: 32),
            duration: rawDuration.isFinite ? max(0, rawDuration) : 0,
            albumID: opaqueAlbumID,
            explicit: nil,
            isPlayable: true,
            format: badge.flatMap { $0.isEmpty ? nil : $0 })
    }
}
