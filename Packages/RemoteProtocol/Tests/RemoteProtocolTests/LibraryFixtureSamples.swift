import Foundation
import RemoteProtocol

extension FixtureSamples {
    static let libraryCommands: [Command] = [
        .playLibrary(itemId: "m_0123456789abcdef0123456789abcdef", from: .resume, shuffle: false),
        .resumeSource(source: .localMusic),
    ]

    static let libraryItem = RemoteLibraryItem(
        id: "m_0123456789abcdef0123456789abcdef",
        kind: .movie,
        title: "Ember Dusk",
        subtitle: "2025 · Science Fiction",
        year: 2025,
        rating: 8.5,
        ratingScale: 10,
        genres: ["Science Fiction"],
        badges: ["4K HDR", "MKV"],
        duration: 7083,
        progress: .init(position: 1200, duration: 7083, completed: false),
        folderName: "Movies",
        offline: false,
        artwork: true)

    static let localMusicTrack = RemoteMusicTrack(
        id: "t_0123456789abcdef0123456789abcdef",
        title: "Evening Line",
        artists: ["Mira Lune"],
        album: "Quiet Hours",
        year: "2025",
        duration: 180,
        albumID: "a_0123456789abcdef0123456789abcdef",
        isPlayable: true,
        format: "FLAC · 24/96")

    static let librarySamples: [FixtureSample] = [
        FixtureSample(
            name: "requestState-features",
            message: .requestState(header, .init(features: ["library.v1"]))),
        FixtureSample(
            name: "state-library",
            message: .state(
                header,
                .init(
                    title: "Evening Line", position: 42, duration: 180, paused: false, volume: 65,
                    fullscreen: false, hasMedia: true, canNext: true, canPrevious: false,
                    screensaver: .off, source: .music,
                    music: .init(
                        track: localMusicTrack, nextTrack: nil, liked: false, shuffle: false,
                        repeatMode: .off, queueCount: 3, queueRevision: serverId,
                        libraryRevision: deviceId, outputName: "Mac mini",
                        disallowedActions: ["like", "similar", "skipping_prev"],
                        positionAge: 0, volumeKnown: true, origin: .local),
                    library: .init(
                        revision: serverId, progressRevision: deviceId, folders: 2, videos: 12,
                        series: 3, albums: 8, tracks: 94, scanning: false),
                    sources: .init(
                        video: .init(
                            title: "Ember Dusk", subtitle: "2025 · Science Fiction", paused: true,
                            artwork: "m_0123456789abcdef0123456789abcdef"),
                        localMusic: .init(
                            title: "Evening Line", subtitle: "Mira Lune · Quiet Hours",
                            paused: false, artwork: "t_0123456789abcdef0123456789abcdef"),
                        spotify: nil)))),
        FixtureSample(
            name: "requestLibrary",
            message: .requestLibrary(
                header,
                .init(
                    section: .videos, videoKind: .movies, sort: .rating, query: "Ember",
                    offset: 0, revision: serverId))),
        FixtureSample(
            name: "library",
            message: .library(
                header,
                .init(
                    replyTo: replyId, revision: serverId, section: .videos, offset: 0, total: 1,
                    nextOffset: nil, items: [libraryItem]))),
        FixtureSample(
            name: "requestLibraryItem",
            message: .requestLibraryItem(
                header, .init(id: "m_0123456789abcdef0123456789abcdef"))),
        FixtureSample(
            name: "libraryItem",
            message: .libraryItem(
                header,
                .init(
                    replyTo: replyId, revision: serverId, item: libraryItem,
                    details: .init(
                        overview: "A quiet journey beyond the orbit.",
                        ratingSource: "IMDb",
                        fileName: "Ember Dusk.mkv",
                        folderName: "Movies",
                        audioLanguages: ["eng"],
                        subtitleLanguages: ["eng", "rus"],
                        seasons: [])))),
        FixtureSample(
            name: "requestArtwork",
            message: .requestArtwork(
                header, .init(id: "m_0123456789abcdef0123456789abcdef", maxPixel: 240))),
        FixtureSample(
            name: "artwork",
            message: .artwork(
                header,
                .init(
                    replyTo: replyId, id: "m_0123456789abcdef0123456789abcdef",
                    jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9])))),
    ]
}
