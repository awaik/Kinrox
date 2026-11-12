import AppKit
import Foundation
import MusicCore
import SwiftUI
import Testing

@testable import Kinrox

extension DiscoveryServiceTests {
    @Test(arguments: [false, true])
    func twentyThousandTrackRefreshBoundsMainActorOccupancy(unseeded: Bool) async throws {
        DiscoveryHTTPStub.state.reset([])
        let tracks = Self.scaleTracks()
        let album = MusicAlbum(
            id: "full", uri: "full", title: "Library", artists: [], year: "2026",
            trackIDs: tracks.map(\.id))
        let store = makeStore()
        store.catalog = MusicCatalog(tracks: tracks, albums: [album])
        store.library = LibrarySnapshot(
            userID: "synthetic", likedTrackIDs: Set(tracks.prefix(5_000).map(\.id)),
            savedAlbumIDs: [album.id],
            playlists: [
                .init(
                    id: "p", uri: "p", title: "Mix", ownerID: "synthetic",
                    trackIDs: tracks.prefix(100).map(\.id))
            ])
        let session = UUID()
        store.playHistory = (0..<5_000).map { index in
            MusicPlayHistoryEntry(
                sessionID: session, trackID: "t\(index)", previousTrackID: "t\(max(0, index - 1))",
                playedAt: Date(), playedSeconds: 200, completed: true, skipped: false)
        }
        let seed = unseeded ? nil : tracks[0]
        var data = SpotifyDiscoveryData()
        data.tracks = Array(tracks.suffix(80))
        data.signals = data.tracks.map { .init(track: $0, kind: .listenBrainzRecording) }
        let key = store.discoverySeedKey(track: seed, artist: seed?.artists.first)
        store.discoveryCache["seed-v2|\(key)|0"] = (Date(), data)
        let model = MusicViewModel(store: store)
        model.selection = BrowserSelection(source: .similar)
        model.discoverySeedTrack = seed
        model.discoverySeedArtist = seed?.artists.first
        // A mounted empty workspace matches an already-launched Mac window. These windows
        // never order front, play audio, touch owner defaults, or perform network requests.
        let host = DiscoveryTimedHost(rootView: DiscoveryWorkspaceView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let turns = DiscoveryMainRunLoopProbe()
        host.longestLayout = .zero
        let heartbeat = Task.detached {
            var longest = Duration.zero
            while !Task.isCancelled {
                let queued = ContinuousClock.now
                let served = await MainActor.run { ContinuousClock.now }
                longest = max(longest, queued.duration(to: served))
                try? await Task.sleep(for: .milliseconds(5))
            }
            return longest
        }
        defer { heartbeat.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        var publication = Duration.zero
        let onChange = store.onChange
        store.onChange = {
            let start = ContinuousClock.now
            onChange?()
            publication = max(publication, start.duration(to: .now))
        }
        let refreshStart = ContinuousClock.now
        model.refreshDiscovery()
        let refresh = refreshStart.duration(to: .now)
        // Seed/header is available before background results.
        #expect(model.discoverySnapshot != nil)
        // Let AppKit schedule the observation update normally. Forcing layout in the
        // caller's same synchronous turn artificially joins otherwise separate occupancies.
        try await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
        await model.browsingTask?.value
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        heartbeat.cancel()
        let schedulingDelay = await heartbeat.value
        turns.stop()
        let occupancy = max(refresh, publication, host.longestLayout, turns.longestOccupancy)
        print(
            "METRIC discovery-main unseeded=\(unseeded) refresh=\(refresh) "
                + "publication=\(publication) longest-layout=\(host.longestLayout) "
                + "longest-runloop-occupancy=\(turns.longestOccupancy) "
                + "max-main-queue-delay=\(schedulingDelay)")
        #if DEBUG
            #expect(occupancy < .milliseconds(2_000))
        #else
            #expect(occupancy < .milliseconds(250))
        #endif
        #expect(model.statusMessage == nil)
        #expect(model.discoverySnapshot?.items.isEmpty == false)
        #expect(store.catalog.tracks.count == 20_000)
        #expect(DiscoveryHTTPStub.state.requests.isEmpty)
        window.contentView = nil
        model.setWorkspaceActive(false)
        store.retire()
        await store.client.close()
    }

    @Test func leavingSimilarDuringDeferredPreviewStillShowsResultsOnReturn() async throws {
        DiscoveryHTTPStub.state.reset([])
        let tracks = Self.scaleTracks()
        let store = makeStore()
        store.catalog = MusicCatalog(tracks: tracks)
        store.library = LibrarySnapshot(
            userID: "synthetic", likedTrackIDs: Set(tracks.prefix(500).map(\.id)))
        var data = SpotifyDiscoveryData()
        data.tracks = Array(tracks.suffix(80))
        data.signals = data.tracks.map { .init(track: $0, kind: .listenBrainzRecording) }
        let key = store.discoverySeedKey(track: tracks[0], artist: tracks[0].artists.first)
        store.discoveryCache["seed-v2|\(key)|0"] = (Date(), data)
        store.isConnected = true
        let model = MusicViewModel(store: store)
        model.discoverySeedTrack = tracks[0]
        model.discoverySeedArtist = tracks[0].artists.first
        // Leave Similar in the same main-actor turn, before the background preview finishes.
        model.select(.similar)
        #expect(model.isDiscovering)
        model.select(.liked)
        let deadline = ContinuousClock.now + .seconds(20)
        while model.isDiscovering, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.select(.similar)
        while model.isDiscovering, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.isDiscovering)
        #expect(model.discoverySnapshot?.items.isEmpty == false)
        model.setWorkspaceActive(false)
        store.retire()
        await store.client.close()
    }

    private static func scaleTracks() -> [MusicTrack] {
        let now = Date()
        return (0..<20_000).map { index in
            let artist = MusicArtist(id: "a\(index % 80)", uri: "a", name: "Artist \(index % 80)")
            let guest = MusicArtist(id: "g\(index % 11)", uri: "g", name: "Guest \(index % 11)")
            let suffix = ["", " [2011 Remaster]", " (Dawn Remix)", " (Club Mix)", " - Live"][
                index % 5]
            return MusicTrack(
                id: "t\(index)", uri: "t\(index)", title: "Song \(index / 2)" + suffix,
                artists: index % 7 == 0 ? [guest, artist] : [artist],
                albumID: "full", albumTitle: "Library", duration: 200,
                addedAt: now.addingTimeInterval(Double(index * 3600)), isrc: "ISRC\(index / 3)")
        }
    }
}

@MainActor
private final class DiscoveryTimedHost: NSHostingView<DiscoveryWorkspaceView> {
    var longestLayout = Duration.zero
    override func layout() {
        let start = ContinuousClock.now
        super.layout()
        longestLayout = max(longestLayout, start.duration(to: .now))
    }
}

/// Measures actual busy intervals, excluding the run loop's sleep. Queue delay alone
/// also includes preceding actor jobs and scheduler latency, so it is reported separately.
@MainActor
private final class DiscoveryMainRunLoopProbe {
    private var observer: CFRunLoopObserver?
    private var began = ContinuousClock.now
    private(set) var longestOccupancy = Duration.zero

    init() {
        let activities =
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) {
            [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                if activity == .afterWaiting {
                    self.began = .now
                } else {
                    self.longestOccupancy = max(
                        self.longestOccupancy, self.began.duration(to: .now))
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }

    func stop() {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }
}
