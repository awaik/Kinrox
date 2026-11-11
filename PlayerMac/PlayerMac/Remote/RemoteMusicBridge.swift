import Foundation
import MusicCore
import RemoteProtocol

/// The LAN remote sees confirmed metadata and opaque occurrences, never Spotify credentials.
@MainActor
final class RemoteMusicBridge {
    let music: MusicViewModel
    let coordinator: PlaybackCoordinator
    private let isActive: () -> Bool
    var changed: (() -> Void)?
    private var observation: UUID?
    private var confirmedQueue = MusicQueue()
    private var confirmedLibrary: LibrarySnapshot
    private(set) var queueRevision = UUID()
    private(set) var libraryRevision = UUID()
    /// Track ID → hidden primary artist, for Undo after the track left the queue.
    private var hiddenArtists: [String: String] = [:]
    private var hiddenTracks: Set<String> = []

    init(
        music: MusicViewModel, coordinator: PlaybackCoordinator,
        isActive: @escaping () -> Bool = { false }
    ) {
        self.music = music
        self.coordinator = coordinator
        self.isActive = isActive
        confirmedLibrary = music.store.library
        confirmedQueue = music.queue
        observation = music.observePlayback { [weak self] _ in self?.update() }
    }
    func disconnect() {
        if let observation { music.removePlaybackObserver(observation) }
        observation = nil
    }
    func update() {
        guard !music.isPlaybackBusy else { return }
        if confirmedQueue != music.queue {
            confirmedQueue = music.queue
            queueRevision = UUID()
        }
        if confirmedLibrary != music.store.library {
            confirmedLibrary = music.store.library
            libraryRevision = UUID()
            queueRevision = UUID()
        }
        changed?()
    }
    var active: Bool { coordinator.activeSource == .music || isActive() }
    var state: MusicState {
        .init(
            track: confirmedQueue.current.map { track($0.track) },
            nextTrack: confirmedQueue.upcoming.first.map { track($0.track) },
            liked: confirmedQueue.current.map {
                confirmedLibrary.likedTrackIDs.contains($0.track.id)
            } ?? false,
            shuffle: confirmedQueue.shuffled,
            repeatMode: RemoteMusicRepeat(rawValue: confirmedQueue.repeatMode.rawValue) ?? .off,
            queueCount: confirmedQueue.items.count, queueRevision: queueRevision,
            libraryRevision: libraryRevision,
            outputName: Self.text(music.outputName),
            status: music.playbackStatusMessage.map { Self.text($0) },
            disallowedActions: music.effectiveDisallowedActions.sorted(),
            favoriteFeedback: music.favoriteFeedbackID.flatMap { id in
                music.favoriteFeedbackLiked.map { .init(id: id, liked: $0) }
            }, positionAge: music.positionAge, volumeKnown: music.volumeKnown,
            similar: .init(
                active: music.isDiscoveryRadioActive && !music.isStartingSimilar,
                finding: music.isStartingSimilar,
                available: music.canStartSimilarFromCurrent))
    }
    func snapshot(fullscreen: Bool, screensaver: Screensaver) -> PlayerState {
        let hasMedia = confirmedQueue.current != nil
        return .init(
            title: confirmedQueue.current.map { Self.text($0.track.title) } ?? "",
            position: hasMedia ? music.position : 0,
            duration: hasMedia ? music.currentTrack?.duration ?? 0 : 0,
            paused: !hasMedia || music.paused,
            volume: music.volumeKnown ? music.volume : 0, fullscreen: fullscreen,
            hasMedia: hasMedia,
            canNext: music.canNext
                && (!confirmedQueue.upcoming.isEmpty || confirmedQueue.repeatMode == .all),
            canPrevious: music.canPrevious && !confirmedQueue.history.isEmpty,
            screensaver: screensaver, source: .music,
            music: state)
    }

    func queuePage(_ request: QueueRequest, replyTo: UUID) -> Message {
        let all = confirmedQueue.items
        let offset =
            request.revision == nil || request.revision == queueRevision
            ? min(request.offset, all.count) : 0
        var count = min(20, all.count - offset)
        while true {
            let items = all.dropFirst(offset).prefix(count).map { item in
                RemoteQueueItem(
                    id: item.id,
                    section: item.id == confirmedQueue.current?.id
                        ? .current : item.origin == .manual ? .manual : .source,
                    track: track(item.track),
                    liked: confirmedLibrary.likedTrackIDs.contains(item.track.id))
            }
            let end = offset + count
            let message = Message.queue(
                .init(),
                .init(
                    replyTo: replyTo, revision: queueRevision, offset: offset,
                    total: all.count, nextOffset: end < all.count ? end : nil, items: items))
            if let bytes = try? Codec.encode(message), bytes.count <= Codec.maxMessageBytes - 28 {
                return message
            }
            guard count > 1 else { return failure(replyTo) }
            count /= 2
        }
    }

    func likeOptionsPage(_ request: LikeOptionsRequest, replyTo: UUID) -> Message {
        guard let track = findTrack(request.trackId) else { return failure(replyTo) }
        let all =
            (confirmedLibrary.playlists.filter { $0.isEditable(by: confirmedLibrary.userID) }.map {
                RemoteLikeOption(
                    id: $0.id, kind: .playlist, title: Self.text($0.title),
                    selected: $0.trackIDs.contains(track.id))
            }
            + track.artists.map {
                RemoteLikeOption(
                    id: $0.id, kind: .artist, title: Self.text($0.name),
                    selected: confirmedLibrary.followedArtistIDs.contains($0.id))
            }).filter {
                $0.isValid && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        let offset =
            request.revision == nil || request.revision == libraryRevision
            ? min(request.offset, all.count) : 0
        var count = min(20, all.count - offset)
        while true {
            let items = Array(all.dropFirst(offset).prefix(count))
            let end = offset + items.count
            let message = Message.likeOptions(
                .init(),
                .init(
                    replyTo: replyTo, trackId: request.trackId, revision: libraryRevision,
                    offset: offset, total: all.count, nextOffset: end < all.count ? end : nil,
                    items: items,
                    liked: confirmedLibrary.likedTrackIDs.contains(request.trackId)))
            if let bytes = try? Codec.encode(message), bytes.count <= Codec.maxMessageBytes - 28 {
                return message
            }
            guard count > 1 else { return failure(replyTo) }
            count /= 2
        }
    }

    func execute(_ command: Command) -> ProtocolError.Code? {
        guard active else { return .noMedia }
        if let action = command.musicAction(paused: music.paused, repeatMode: state.repeatMode),
            music.effectiveDisallowedActions.contains(action)
        {
            return .invalidPayload
        }
        switch command {
        case .togglePause: music.togglePause()
        case .setPaused(let value): music.setPaused(value)
        case .seekRelative(let seconds): music.seek(music.displayedPosition + seconds)
        case .seekAbsolute(let seconds): music.seek(seconds)
        case .setVolume(let value): music.setVolume(value)
        case .next:
            guard !music.queue.upcoming.isEmpty || music.queue.repeatMode == .all else {
                return .itemNotFound
            }
            music.next()
        case .previous:
            guard !music.queue.history.isEmpty else { return .itemNotFound }
            music.previous()
        case .setShuffle(let value): music.setShuffle(value)
        case .setRepeat(let value): music.setRepeat(MusicRepeat(rawValue: value.rawValue) ?? .off)
        case .queueRemove(let id):
            guard music.queue.upcoming.contains(where: { $0.id == id }) else {
                return .itemNotFound
            }
            music.removeFromQueue(id)
        case .queueMove(let id, let target):
            guard music.queue.upcoming.contains(where: { $0.id == id }),
                music.queue.upcoming.contains(where: { $0.id == target })
            else { return .itemNotFound }
            music.moveQueue(id, before: target)
        case .setSimilar(let active):
            if !active {
                music.stopSimilar()
            } else if !music.startSimilarFromCurrent() {
                return music.hasTrack ? .internal : .noMedia
            }
        case .setNotInterested(let id, let scope, let excluded):
            return excluded ? hide(trackID: id, scope: scope) : unhide(trackID: id, scope: scope)
        default: return executeFavorite(command)
        }
        return nil
    }

    private func hide(trackID: String, scope: RemoteNotInterestedScope) -> ProtocolError.Code? {
        guard let track = findTrack(trackID) else { return .itemNotFound }
        guard scope == .artist else {
            if hiddenTracks.count >= 64 { hiddenTracks.removeAll() }
            if music.hideFromSimilar(track, artist: nil) {
                hiddenTracks.insert(trackID)
            } else {
                hiddenTracks.remove(trackID)
            }
            return nil
        }
        guard let artist = track.artists.first else { return .itemNotFound }
        if hiddenArtists.count >= 64 { hiddenArtists.removeAll() }
        hiddenArtists[trackID] = music.hideFromSimilar(track, artist: artist) ? artist.id : nil
        return nil
    }

    /// Undo may arrive after the hidden track has left the queue, so it needs only the ID.
    private func unhide(trackID: String, scope: RemoteNotInterestedScope) -> ProtocolError.Code? {
        guard scope == .artist else {
            if hiddenTracks.remove(trackID) != nil {
                music.unhideFromSimilar(trackID: trackID, artistID: nil)
            }
            return nil
        }
        guard let artist = hiddenArtists.removeValue(forKey: trackID) else { return nil }
        music.unhideFromSimilar(trackID: nil, artistID: artist)
        return nil
    }

    private func executeFavorite(_ command: Command) -> ProtocolError.Code? {
        guard music.canMutate else { return .internal }
        switch command {
        case .setTrackLiked(let id, let liked):
            guard let track = findTrack(id) else { return .itemNotFound }
            music.setTrackLiked(track, liked: liked)
        case .setPlaylistMembership(let id, let playlistId, let included):
            guard findTrack(id) != nil,
                confirmedLibrary.playlists.contains(where: {
                    $0.id == playlistId && $0.isEditable(by: confirmedLibrary.userID)
                })
            else { return .itemNotFound }
            music.setMembership(trackID: id, playlistID: playlistId, included: included)
        case .setArtistFollowed(let id, let followed):
            guard let artist = findArtist(id) else {
                return .itemNotFound
            }
            music.setFollowed(artist, followed: followed)
        case .createPlaylist(let title, let id):
            guard findTrack(id) != nil else {
                return .itemNotFound
            }
            music.createPlaylist(title, trackID: id)
        default: return .unknownMessage
        }
        return nil
    }

    private var knownTracks: [MusicTrack] {
        music.catalog.tracks + confirmedQueue.items.map(\.track) + music.queue.items.map(\.track)
    }

    private func findTrack(_ id: String) -> MusicTrack? {
        music.catalog.track(id: id)
            ?? (confirmedQueue.items + music.queue.items + music.queue.history).first {
                $0.track.id == id
            }?.track
    }

    private func findArtist(_ id: String) -> MusicArtist? {
        music.catalog.artist(id: id)
            ?? knownTracks.lazy.flatMap(\.artists).first { $0.id == id }
    }

    private func track(_ value: MusicTrack) -> RemoteMusicTrack {
        .init(
            id: value.id, title: Self.text(value.title),
            artists: value.artists.prefix(100).map {
                Self.text($0.name, limit: min(128, 3000 / max(1, value.artists.count)))
            },
            album: Self.text(value.albumTitle),
            year: String(
                (music.catalog.album(id: value.albumID)?.year ?? "").prefix(8)),
            duration: value.duration.isFinite ? max(0, value.duration) : 0,
            albumID: value.albumID.isEmpty ? nil : value.albumID, explicit: value.explicit,
            isPlayable: value.isPlayable)
    }
    static func text(_ value: String, limit: Int = 512) -> String { String(value.prefix(limit)) }
    private func failure(_ id: UUID) -> Message {
        .error(.init(), .init(replyTo: id, code: .itemNotFound, message: "Music item unavailable."))
    }
}
