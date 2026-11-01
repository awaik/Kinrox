import Foundation
import RemoteProtocol

extension FixtureSamples {
    static let musicTrack = RemoteMusicTrack(
        id: "track1", title: "Evening Line", artists: ["Mira Lune"],
        album: "Quiet Hours", year: "2025", duration: 180)
    static let musicCommands: [Command] = [
        .setTrackLiked(trackId: "track1", liked: false),
        .setPlaylistMembership(trackId: "track1", playlistId: "playlist1", included: true),
        .setArtistFollowed(artistId: "artist1", followed: true),
        .createPlaylist(title: "Quiet Hours", trackId: "track1"),
        .setShuffle(shuffle: true), .setRepeat(repeatMode: .all),
        .queueMove(itemId: itemId, beforeId: replyId), .queueRemove(itemId: itemId),
    ]
    static let musicSamples: [FixtureSample] = [
        FixtureSample(name: "requestQueue", message: .requestQueue(header, .init(offset: 0))),
        FixtureSample(
            name: "queue",
            message: .queue(
                header,
                .init(
                    replyTo: replyId, revision: serverId,
                    offset: 0, total: 1, nextOffset: nil,
                    items: [.init(id: itemId, section: .current, track: musicTrack)]))),
        FixtureSample(
            name: "requestLikeOptions",
            message: .requestLikeOptions(header, .init(trackId: "track1"))),
        FixtureSample(
            name: "likeOptions",
            message: .likeOptions(
                header,
                .init(
                    replyTo: replyId, trackId: "track1",
                    revision: serverId, offset: 0, total: 1, nextOffset: nil,
                    items: [.init(id: "playlist1", kind: .playlist, title: "Focus", selected: true)]
                ))),
        FixtureSample(
            name: "state-music",
            message: .state(
                header,
                .init(
                    title: "Evening Line", position: 42,
                    duration: 180, paused: false, volume: 0, fullscreen: false, hasMedia: true,
                    canNext: false,
                    canPrevious: false, screensaver: .off, source: .music,
                    music: .init(
                        track: musicTrack, nextTrack: nil, liked: true, shuffle: false,
                        repeatMode: .off,
                        queueCount: 1, queueRevision: serverId, libraryRevision: deviceId,
                        outputName: "Mac mini")))),
    ]
}
