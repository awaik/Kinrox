import Foundation
import Testing

@testable import MusicCore

@Suite(.serialized)
struct DiscoveryScaleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func tracks(_ count: Int) -> [MusicTrack] {
        (0..<count).map { index in
            let artist = MusicArtist(id: "a\(index % 80)", uri: "a", name: "Artist \(index % 80)")
            let guest = MusicArtist(id: "guest\(index % 11)", uri: "g", name: "Guest \(index % 11)")
            let suffix = ["", " [2011 Remaster]", " (Dawn Remix)", " (Club Mix)", " - Live"][
                index % 5]
            return MusicTrack(
                id: "t\(index)", uri: "t\(index)", title: "Song \(index / 2)" + suffix,
                artists: index % 7 == 0 ? [guest, artist] : [artist],
                albumID: "album\(index / 20)", albumTitle: "Album", duration: 200,
                addedAt: now.addingTimeInterval(Double(index * 3600)), isrc: "ISRC\(index / 3)")
        }
    }

    @Test(arguments: [false, true])
    func twentyThousandTrackStartupIsBounded(unseeded: Bool) {
        let tracks = tracks(20_000)
        let catalog = MusicCatalog(tracks: tracks)
        let liked = Set(tracks.prefix(5_000).map(\.id))
        let library = LibrarySnapshot(
            userID: "synthetic", likedTrackIDs: liked,
            playlists: [
                .init(
                    id: "p", uri: "p", title: "Mix", ownerID: "synthetic",
                    trackIDs: Array(tracks.prefix(100).map(\.id)))
            ])
        let session = UUID()
        let history = (0..<5_000).map { index in
            MusicPlayHistoryEntry(
                sessionID: session, trackID: "t\(index)", previousTrackID: "t\(max(0, index - 1))",
                playedAt: now, playedSeconds: 200, completed: true, skipped: false)
        }
        let compilationTracks = Array(tracks.suffix(12))
        let compilation = MusicAlbum(
            id: "compilation", uri: "compilation", title: "Compilation",
            artists: [], year: "2026", trackIDs: compilationTracks.map(\.id))
        let seeds = unseeded ? Set<String>() : Set(tracks.prefix(5).map(\.id))
        // A large library and realistic bounded provider response exercise startup's seed cross-product.
        let signals = tracks.suffix(80).map {
            MusicDiscoverySignal(track: $0, kind: .listenBrainzRecording)
        }
        func build() -> MusicDiscoverySnapshot {
            MusicDiscoveryEngine.build(
                seedTrackIDs: seeds, catalog: catalog, library: library,
                compilationAlbums: [(compilation, compilationTracks)], signals: signals,
                history: history, now: now)
        }
        let start = ContinuousClock.now
        let result = autoreleasepool { build() }
        let elapsed = start.duration(to: .now)
        #expect(!result.items.isEmpty)
        #expect(result == autoreleasepool { build() })
        #if DEBUG
            // Orchestrator clarification, 2026-11-12: this catches the old tens-of-seconds
            // quadratic/regex-per-pair regression; 250 ms is the MainActor occupancy bound.
            print("Discovery scale unseeded=\(unseeded): \(elapsed), items=\(result.items.count)")
            #expect(elapsed < .milliseconds(2_000))
        #else
            // The first result warms the runtime. Keep full output and measure 15 more builds.
            var times: [Duration] = []
            for _ in 0..<15 {
                let start = ContinuousClock.now
                let next = autoreleasepool { build() }
                times.append(start.duration(to: .now))
                #expect(next == result)
            }
            times.sort()
            print(
                "Discovery release unseeded=\(unseeded): median=\(times[7]), "
                    + "p95=\(times[14]), max=\(times[14]), items=\(result.items.count)")
            #expect(times[7] < .milliseconds(250))
        #endif
    }

    @Test func rankingMatchesFrozenSpecification() {
        var tracks = tracks(240)
        // The third item bridges two live slots by ISRC and swapped artist billing.
        let fixture = MusicDiscoveryRankingTests()
        tracks += [
            fixture.track("bridge-a", artist: "A", title: "Night", isrc: "ONE"),
            fixture.track("bridge-b", artist: "B", title: "Day", isrc: "TWO"),
            fixture.track("bridge-c", artist: "B", title: "Day (Dawn Remix)", isrc: "ONE"),
        ]
        let catalog = MusicCatalog(tracks: tracks)
        let library = LibrarySnapshot(userID: "u")
        let signals = tracks.enumerated().map {
            MusicDiscoverySignal(
                track: $0.element, kind: $0.offset % 2 == 0 ? .collaborator : .remixer)
        }
        for mode in MusicDiscoveryMode.allCases {
            let expected = autoreleasepool {
                ReferenceDiscoveryEngine.build(
                    seedTrackIDs: ["t0"], mode: mode, hideLiked: false,
                    catalog: catalog, library: library, signals: signals, now: now)
            }
            let actual = MusicDiscoveryEngine.build(
                seedTrackIDs: ["t0"], mode: mode, hideLiked: false,
                catalog: catalog, library: library, signals: signals, now: now)
            #expect(actual == expected)
        }
    }
}
