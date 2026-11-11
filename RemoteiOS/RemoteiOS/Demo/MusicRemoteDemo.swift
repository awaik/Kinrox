import Foundation
import MusicCore
import RemoteProtocol

@MainActor
final class MusicRemoteDemo {
    let catalog = MusicDemo.catalog
    var library = MusicDemo.library
    var queue = MusicQueue()
    var paused = false
    var position: Double = 84
    var volume: Double = 0
    var queueRevision = UUID()
    var libraryRevision = UUID()
    var similarActive = false
    var hiddenTrackIDs: Set<String> = []
    var hiddenArtists: Set<String> = []
    init() {
        if let album = catalog.albums.first(where: { $0.id == "evening" }) {
            queue.start(catalog.tracks(in: album), at: 2)
        }
        if let track = catalog.tracks.last { queue.add(track) }
    }
    func perform(_ command: Command) {
        switch command {
        case .togglePause: paused.toggle()
        case .setPaused(let value): paused = value
        case .seekRelative(let value):
            position = min(queue.current?.track.duration ?? 0, max(0, position + value))
        case .seekAbsolute(let value):
            position = min(queue.current?.track.duration ?? 0, max(0, value))
        case .setVolume(let value): volume = value
        case .next: if queue.next() != nil { position = 0 }
        case .previous: if queue.previous() != nil { position = 0 }
        case .setTrackLiked(let id, let value):
            library.apply(FavoritesPolicy.track(id, liked: value, in: library).mutations)
        case .setPlaylistMembership(let track, let playlist, let included):
            library.apply(
                FavoritesPolicy.membership(
                    trackID: track, playlistID: playlist, included: included, in: library
                ).mutations)
        case .setArtistFollowed(let id, let value):
            library.apply(FavoritesPolicy.artist(id, followed: value, in: library).mutations)
        case .createPlaylist(let title, let track):
            library.playlists.append(
                .init(
                    id: UUID().uuidString, uri: "", title: title, ownerID: library.userID,
                    trackIDs: [track]))
        case .setShuffle(let value):
            var random = SystemRandomNumberGenerator()
            queue.setShuffle(value, using: &random)
        case .setRepeat(let value): queue.repeatMode = MusicRepeat(rawValue: value.rawValue) ?? .off
        case .queueMove(let id, let target): queue.move(id, before: target)
        case .queueRemove(let id): queue.remove(id)
        case .setSimilar(let value): setSimilar(value)
        case .setNotInterested(let id, let scope, let excluded):
            guard let track = catalog.tracks.first(where: { $0.id == id }) else { break }
            hide(track, scope: scope, excluded: excluded)
        default: break
        }
        queueRevision = UUID()
        libraryRevision = UUID()
    }
    private func setSimilar(_ value: Bool) {
        similarActive = value && queue.current != nil
        guard similarActive else { return }
        let kept = Set((queue.items.prefix(1 + queue.manual.count) + queue.history).map(\.track.id))
        queue.replaceSource(
            catalog.tracks.filter {
                !kept.contains($0.id) && !hiddenTrackIDs.contains($0.id)
                    && hiddenArtists.isDisjoint(with: $0.artists.map(\.name))
            })
    }

    private func hide(_ track: MusicTrack, scope: RemoteNotInterestedScope, excluded: Bool) {
        let artist = track.artists.first?.name
        if scope == .artist, let artist {
            if excluded { hiddenArtists.insert(artist) } else { hiddenArtists.remove(artist) }
        } else if excluded {
            hiddenTrackIDs.insert(track.id)
        } else {
            hiddenTrackIDs.remove(track.id)
        }
        guard excluded, similarActive else { return }
        let matches: (MusicTrack) -> Bool = {
            scope == .artist ? $0.artists.first?.name == artist : $0.id == track.id
        }
        for item in queue.source where matches(item.track) { queue.remove(item.id) }
        if let current = queue.current, matches(current.track), queue.next() != nil {
            position = 0
        }
    }

    func track(_ item: MusicTrack) -> RemoteMusicTrack {
        .init(
            id: item.id, title: item.title, artists: item.artists.map(\.name),
            album: item.albumTitle,
            year: catalog.albums.first { $0.id == item.albumID }?.year ?? "",
            duration: item.duration, albumID: item.albumID, explicit: item.explicit,
            isPlayable: item.isPlayable)
    }
    var state: PlayerState {
        .init(
            title: queue.current?.track.title ?? "", position: position,
            duration: queue.current?.track.duration ?? 0,
            paused: paused, volume: volume, fullscreen: false, hasMedia: queue.current != nil,
            canNext: !queue.upcoming.isEmpty || queue.repeatMode == .all,
            canPrevious: !queue.history.isEmpty,
            screensaver: .off, source: .music,
            music: .init(
                track: queue.current.map { track($0.track) },
                nextTrack: queue.upcoming.first.map { track($0.track) },
                liked: queue.current.map { library.likedTrackIDs.contains($0.track.id) } ?? false,
                shuffle: queue.shuffled,
                repeatMode: RemoteMusicRepeat(rawValue: queue.repeatMode.rawValue) ?? .off,
                queueCount: queue.items.count,
                queueRevision: queueRevision, libraryRevision: libraryRevision,
                outputName: "MacBook Pro",
                similar: .init(active: similarActive, available: queue.current != nil)))
    }
}

extension RemoteAppModel {
    func enableMusicDemo() {
        guard isDemo else { return }
        musicDemo = MusicRemoteDemo()
        syncMusicDemo()
    }
    func syncMusicDemo() {
        guard let musicDemo else { return }
        let previous = state
        state = musicDemo.state
        receivedAt = scheduler.now
        frozenPosition = state.position
        hasState = true
        musicStateChanged(from: previous)
        syncMusicDemoPages()
        lockScreenStateChanged()
    }
    func syncMusicDemoPages() {
        guard let demo = musicDemo else { return }
        musicQueue = demo.queue.items.map {
            .init(
                id: $0.id,
                section: $0.id == demo.queue.current?.id
                    ? .current : $0.origin == .manual ? .manual : .source,
                track: demo.track($0.track), liked: demo.library.likedTrackIDs.contains($0.track.id)
            )
        }
        let id = likeOptionsTrackID ?? pendingLikeTrackID
        if let id, let track = demo.catalog.tracks.first(where: { $0.id == id }) {
            likeOptions =
                demo.library.playlists.filter { $0.isEditable(by: demo.library.userID) }.map {
                    .init(
                        id: $0.id, kind: .playlist, title: $0.title,
                        selected: $0.trackIDs.contains(id))
                }
                + track.artists.map {
                    .init(
                        id: $0.id, kind: .artist, title: $0.name,
                        selected: demo.library.followedArtistIDs.contains($0.id))
                }
            if pendingLikeTrackID == id, demo.library.likedTrackIDs.contains(id) {
                pendingLikeTrackID = nil
                likeOptionsTrackID = id
                showsLikeOptions = true
            }
        }
    }
}
