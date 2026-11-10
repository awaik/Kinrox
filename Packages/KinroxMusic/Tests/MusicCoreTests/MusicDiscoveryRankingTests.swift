import Foundation
import Testing

@testable import MusicCore

struct MusicDiscoveryRankingTests {
    @Test func relaxedDiversityStillCapsSeedArtist() {
        let seed = track("seed", artist: "Seed")
        let candidates = (0..<8).map { track("own\($0)", artist: "Seed") }
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], hideLiked: false, catalog: MusicCatalog(tracks: [seed]),
            library: LibrarySnapshot(userID: "u"),
            signals: candidates.map { .init(track: $0, kind: .listenBrainzRecording) })
        #expect(result.tracks.count == 3)
    }
    @Test func diversityKeepsAllCandidatesAfterCappedPass() {
        let tracks = (0..<5).flatMap { artist in
            (0..<5).map { track("\(artist)-\($0)", artist: "Artist \(artist)") }
        }
        let result = MusicDiscoveryEngine.build(
            hideLiked: false, catalog: MusicCatalog(), library: LibrarySnapshot(userID: "u"),
            signals: tracks.map { .init(track: $0, kind: .collaborator) })
        #expect(result.items.count == 25)
        let firstPass = Dictionary(grouping: result.tracks.prefix(10), by: { $0.artists[0].id })
        #expect(firstPass.count == 5)
        #expect(firstPass.values.allSatisfy { $0.count == 2 })
    }

    @Test func remixerRequiresAnArtistNameAndAnExactCredit() {
        for qualifier in ["Vocal", "Extended Club", "Original Vocal", "2026", "Live", "Radio Edit"]
        {
            #expect(MusicDiscoveryIdentity.remixers(in: "Song (\(qualifier) Mix)").isEmpty)
        }
        #expect(MusicDiscoveryIdentity.remixers(in: "Song (Dawn Remix)") == ["Dawn"])
        let seed = track("seed", artist: "Seed", title: "Song (Dawn Remix)")
        let unrelated = track("unrelated", title: "Before the Dawn")
        let remix = track("remix", title: "Another Song (Dawn Remix)")
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], hideLiked: false,
            catalog: MusicCatalog(tracks: [seed, unrelated, remix]),
            library: LibrarySnapshot(userID: "u"))
        #expect(result.tracks.map(\.id) == [remix.id])
    }

    let artist = MusicArtist(
        id: "seedArtist", uri: "spotify:artist:seedArtist", name: "Christian Löffler")
    func track(
        _ id: String, artist: String = "Other", title: String? = nil, isrc: String? = nil,
        date: String? = nil, added: Date? = nil
    ) -> MusicTrack {
        MusicTrack(
            id: id, uri: "spotify:track:\(id)", title: title ?? id,
            artists: [MusicArtist(id: artist, uri: "spotify:artist:\(artist)", name: artist)],
            albumID: "album", albumTitle: "Album", duration: 200, addedAt: added, isrc: isrc,
            releaseDate: date)
    }
    @Test func variantsShareIsrcOrSwappedBillingAndMergeReasons() {
        let seed = track("seed", artist: "Christian Löffler", title: "Refu", isrc: "SEED")
        let swapped = MusicTrack(
            id: "swapped", uri: "spotify:track:swapped", title: "Refu (Dominik Eulberg Remix)",
            artists: [
                MusicArtist(id: "remixer", uri: "spotify:artist:remixer", name: "Dominik Eulberg"),
                artist,
            ], albumID: "a", albumTitle: "A", duration: 200)
        let sameISRC = track("isrcSeed", title: "Different spelling", isrc: "seed")
        let a = track("a", title: "Night", isrc: "SAME")
        let b = track("b", title: "Night - 2026 Remaster", isrc: "same")
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], hideLiked: false,
            catalog: MusicCatalog(tracks: [seed]), library: LibrarySnapshot(userID: "u"),
            signals: [
                .init(track: swapped, kind: .listenBrainzRecording),
                .init(track: sameISRC, kind: .listenBrainzRecording),
                .init(track: a, kind: .listenBrainzRecording), .init(track: b, kind: .collaborator),
            ])
        #expect(result.tracks.map(\.id) == ["a"])
        #expect(result.items.first?.reasons.map(\.kind) == [.listenBrainzRecording, .collaborator])
    }
    @Test(arguments: MusicDiscoveryMode.allCases) func seedPenaltyAppliesInEveryMode(
        mode: MusicDiscoveryMode
    ) throws {
        let seed = track("seed", artist: "Seed")
        let own = track("own", artist: "Seed")
        let other = track("other")
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], mode: mode, hideLiked: false,
            catalog: MusicCatalog(tracks: [seed]), library: LibrarySnapshot(userID: "u"),
            signals: [own, other].map { .init(track: $0, kind: .listenBrainzRecording) })
        #expect(try #require(result.items.first { $0.id == own.id }).score == 0.35)
        #expect(result.tracks.first?.id == other.id)
    }
    @Test func idfUsesPlaylistSizeAndIsIndependentOfIterationOrder() throws {
        let seed = track("seed")
        let a = track("a")
        let b = track("b", artist: "B")
        let small = MusicPlaylist(
            id: "s", uri: "s", title: "Small", ownerID: "u", trackIDs: [seed.id, a.id])
        let large = MusicPlaylist(
            id: "l", uri: "l", title: "Large", ownerID: "u",
            trackIDs: [seed.id, b.id] + (0..<100).map { "missing\($0)" })
        let catalog = MusicCatalog(tracks: [seed, a, b])
        func build(_ playlists: [MusicPlaylist]) -> MusicDiscoverySnapshot {
            MusicDiscoveryEngine.build(
                seedTrackIDs: [seed.id], hideLiked: false, catalog: catalog,
                library: LibrarySnapshot(userID: "u", playlists: playlists))
        }
        let first = build([small, large])
        let reversed = build([large, small])
        #expect(first == reversed)
        #expect(
            try #require(first.items.first { $0.id == "a" }).score
                > #require(first.items.first { $0.id == "b" }).score)
        #expect(first.mixes.count == 2)
        #expect(first.items.allSatisfy { $0.reasonKind == .ownPlaylist })
        var unreadable = small
        unreadable.itemsAvailable = false
        #expect(build([unreadable]).items.isEmpty)
    }
    @Test func negativeFeedbackHistoryAndConfirmedGenreOnly() {
        let seed = track("seed", artist: "Seed")
        let a = track("a")
        let b = track("b", artist: "B")
        let c = track("c", artist: "C")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UUID()
        let history = [
            MusicPlayHistoryEntry(
                sessionID: session, trackID: "a", previousTrackID: "seed", playedAt: now,
                playedSeconds: 200, completed: true, skipped: false),
            MusicPlayHistoryEntry(
                sessionID: session, trackID: "b", playedAt: now, playedSeconds: 5, completed: false,
                skipped: true),
            MusicPlayHistoryEntry(
                sessionID: session, trackID: "b", playedAt: now, playedSeconds: 5, completed: false,
                skipped: true),
        ]
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], genres: ["ambient"], hideLiked: false,
            catalog: MusicCatalog(tracks: [seed, a, b, c]), library: LibrarySnapshot(userID: "u"),
            signals: [b, c].map { .init(track: $0, kind: .collaborator) }, history: history,
            notInterestedArtistIDs: ["C"], now: now)
        #expect(result.tracks.map(\.id) == ["a"])
        #expect(result.items.first?.score == 0.3)
        #expect(result.sections.map(\.kind) == [.yourPlaylists])
        #expect(result.genreSource == .spotify)
    }
    @Test func localCollaboratorsLikesAndDefaultSeedHaveRealEvidence() {
        let date = Date()
        let seed = track("seed", artist: "Seed", added: date)
        let collaborator = MusicArtist(id: "C", uri: "c", name: "C")
        let joint = MusicTrack(
            id: "joint", uri: "joint", title: "Duet", artists: seed.artists + [collaborator],
            albumID: "a", albumTitle: "A", duration: 200)
        let solo = track("solo", artist: "C")
        let liked = track("liked", artist: "L", added: date.addingTimeInterval(100))
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], hideLiked: false,
            catalog: MusicCatalog(tracks: [seed, joint, solo, liked]),
            library: LibrarySnapshot(userID: "u", likedTrackIDs: [liked.id]))
        #expect(result.items.contains { $0.id == solo.id && $0.reasonKind == .collaborator })
        #expect(result.items.contains { $0.id == liked.id && $0.reasonKind == .likedSameDay })
        #expect(result.mixes.isEmpty)
    }
    @Test func freshnessUsesInjectedDateAndUndergroundRequiresUnknownArtist() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = track("fresh", date: "2026-11-01")
        let old = track("old", artist: "Old", date: "2020")
        let signals = [fresh, old].map {
            MusicDiscoverySignal(track: $0, kind: .listenBrainzArtist, lowerHalf: true)
        }
        let result = MusicDiscoveryEngine.build(
            mode: .fresh, hideLiked: false, catalog: MusicCatalog(),
            library: LibrarySnapshot(userID: "u"), signals: signals, now: now)
        #expect(try #require(result.items.first { $0.id == fresh.id }).score == 0.8 * 1.35)
        #expect(try #require(result.items.first { $0.id == old.id }).score == 0.8)
        let underground = MusicDiscoveryEngine.build(
            seedArtistIDs: ["Seed"], mode: .underground, hideLiked: false, catalog: MusicCatalog(),
            library: LibrarySnapshot(userID: "u", followedArtistIDs: ["Other"]), signals: signals)
        #expect(try #require(underground.items.first { $0.id == old.id }).score == 0.8 * 1.35)
        #expect(try #require(underground.items.first { $0.id == fresh.id }).score == 0.8)
    }
    @Test func simplifiedMergeAndSourceAppendPreserveIdentity() throws {
        let full = track("full", isrc: "AB123", date: "2026-11-01")
        var catalog = MusicCatalog(tracks: [full])
        catalog.merge(tracks: [track("full")])
        #expect(catalog.track(id: "full")?.isrc == full.isrc)
        #expect(catalog.track(id: "full")?.releaseDate == full.releaseDate)
        var queue = MusicQueue()
        queue.start([full])
        queue.add(track("manual"))
        queue.appendSource([track("radio")])
        #expect(queue.manual.map(\.track.id) == ["manual"])
        #expect(queue.source.map(\.track.id) == ["radio"])
        #expect(queue.source.first?.sourceOrder == 1)
        #expect(queue.context.count == 2)
        #expect(queue.source.first?.origin == .source)
    }
}
