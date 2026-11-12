import Foundation
import MusicCore

extension MusicViewModel {
    var currentDiscoverySeed: MusicDiscoverySeed {
        if discoverySeedTitle.isEmpty { return discoverySnapshot?.seed ?? .init() }
        return .init(
            title: discoverySeedTitle,
            artistNames: discoverySeedTrack?.artistNames ?? discoverySeedArtist?.name ?? "",
            trackID: discoverySeedTrack?.id, artistID: discoverySeedArtist?.id)
    }
    func rememberDiscoverySeed(_ seed: MusicDiscoverySeed) {
        if let id = seed.trackID, let track = discoverySeedTrack ?? catalog.track(id: id) {
            discoveryHistoryTracks[id] = track
        }
        if let id = seed.artistID, let artist = discoverySeedArtist ?? catalog.artist(id: id) {
            discoveryHistoryArtists[id] = artist
        }
    }
    func pruneDiscoverySeedHistory() {
        let tracks = Set(discoverySeedHistory.compactMap(\.trackID))
        let artists = Set(discoverySeedHistory.compactMap(\.artistID))
        discoveryHistoryTracks = discoveryHistoryTracks.filter { tracks.contains($0.key) }
        discoveryHistoryArtists = discoveryHistoryArtists.filter { artists.contains($0.key) }
    }
    var canGoBackDiscovery: Bool { !discoverySeedHistory.isEmpty }
    func goBackDiscoverySeed() {
        guard let seed = discoverySeedHistory.popLast() else { return }
        discoverySeedTitle = seed.title
        discoverySeedAlbumID = nil
        discoverySeedPlaylistID = nil
        discoverySeedTrack = seed.trackID.flatMap {
            catalog.track(id: $0) ?? discoveryHistoryTracks[$0]
        }
        discoverySeedArtist = seed.artistID.flatMap {
            catalog.artist(id: $0) ?? discoveryHistoryArtists[$0]
        }
        discoverySnapshot = nil
        discoverySelectedGenre = nil
        selection.select(source: .similar)
        refreshDiscovery()
    }
    var canUndoNotInterested: Bool { !notInterestedUndo.isEmpty }
    func notInterested(track: MusicTrack) {
        guard notInterestedTrackIDs.insert(track.id).inserted else { return }
        notInterestedUndo.append((track.id, nil))
        persistNotInterested()
    }
    func notInterested(artist: MusicArtist) {
        guard notInterestedArtistIDs.insert(artist.id).inserted else { return }
        notInterestedUndo.append((nil, artist.id))
        persistNotInterested()
    }
    func undoNotInterested() {
        guard let last = notInterestedUndo.popLast() else { return }
        if let track = last.track { notInterestedTrackIDs.remove(track) }
        if let artist = last.artist { notInterestedArtistIDs.remove(artist) }
        persistNotInterested()
    }
    func persistNotInterested(refresh: Bool = true) {
        defaults?.set(
            notInterestedTrackIDs.sorted(), forKey: "app.kinrox.music.notInterestedTracks")
        defaults?.set(
            notInterestedArtistIDs.sorted(), forKey: "app.kinrox.music.notInterestedArtists")
        if refresh, selection.source == .similar { refreshAutomaticDiscovery() }
    }

    func refreshDiscovery() {
        guard isWorkspaceActive, selection.source == .similar else {
            discoveryNeedsRefresh = selection.source == .similar
            return
        }
        discoveryNeedsRefresh = false
        // The setter refreshes Similar itself; avoid launching a second request when it changes.
        if synchronizeDiscoveryConsent(), selection.source == .similar, isWorkspaceActive,
            (store as? SpotifyLibraryStore)?.isRestoring != true
        {
            return
        }
        browsingTask?.cancel()
        let requestID = UUID()
        discoveryRequestID = requestID
        let hasExplicitSeed =
            discoverySeedTrack != nil || discoverySeedArtist != nil
            || !discoverySeedTitle.isEmpty
        let seedTrack = hasExplicitSeed ? discoverySeedTrack : currentTrack
        let seedArtist = discoverySeedArtist ?? seedTrack?.artists.first
        let seedTitle =
            discoverySeedTitle.isEmpty
            ? (seedTrack.map { "\($0.artistNames) — \($0.title)" } ?? L10n.text("Liked tracks"))
            : discoverySeedTitle
        let sameSeed =
            discoverySnapshotConsent == listenBrainzEnabled
            && discoverySnapshot?.seed.trackID == seedTrack?.id
            && discoverySnapshot?.seed.artistID == seedArtist?.id
            && discoverySnapshot?.seed.title == seedTitle
        if !listenBrainzEnabled, discoverySnapshot?.genreSource == .musicBrainz {
            discoverySelectedGenre = nil
        }
        let buildPreview = discoveryPreviewBuilder(
            seedTitle: seedTitle, seedTrack: seedTrack, seedArtist: seedArtist, sameSeed: sameSeed)
        // Small standalone/demo stores retain immediate results. Large libraries yield before
        // ranking so its work cannot join the first SwiftUI update into one long main turn.
        let deferredPreview = catalog.tracks.count > 1_000
        if deferredPreview {
            if !sameSeed {
                discoverySnapshot = .init(
                    seed: .init(
                        title: seedTitle,
                        artistNames: seedTrack?.artistNames ?? seedArtist?.name ?? "",
                        trackID: seedTrack?.id, artistID: seedArtist?.id),
                    mode: discoveryMode, hideLiked: discoveryHideLiked)
            }
        } else {
            applyDiscoveryPreview(autoreleasepool(invoking: buildPreview))
        }
        refreshContents()
        let sourceStore = store
        let connectedStore = (store as? SpotifyLibraryStore).flatMap { $0.isConnected ? $0 : nil }
        discoveryHasConnectedRefresh = connectedStore != nil
        isDiscovering = deferredPreview || connectedStore != nil
        guard isDiscovering else { return }
        connectedStore?.setListenBrainzEnabled(listenBrainzEnabled)
        let mode = discoveryMode
        let hideLiked = discoveryHideLiked
        let excludedTracks = notInterestedTrackIDs
        let excludedArtists = notInterestedArtistIDs
        browsingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.store === sourceStore, self.discoveryRequestID == requestID {
                    self.isDiscovering = false
                }
            }
            do {
                if deferredPreview {
                    let preview = try await MusicDiscoveryComputation.run(buildPreview)
                    guard !Task.isCancelled, self.store === sourceStore,
                        self.discoveryRequestID == requestID, self.selection.source == .similar
                    else { return }
                    self.applyDiscoveryPreview(preview)
                    self.refreshContents()
                }
                guard let store = connectedStore else { return }
                let genre = self.discoverySelectedGenre
                try await self.loadDiscoverySeed(store: store, requestID: requestID)
                guard !Task.isCancelled, self.store === store, self.discoveryRequestID == requestID
                else { return }
                self.synchronizeDiscoveryConsent()
                guard !Task.isCancelled, self.discoveryRequestID == requestID else { return }
                store.setListenBrainzEnabled(self.listenBrainzEnabled)
                let resolvedTrack = self.discoverySeedTrack ?? seedTrack
                let resolvedArtist = self.discoverySeedArtist ?? seedArtist
                let snapshot = try await store.discover(
                    seedTitle: seedTitle, seedTrack: resolvedTrack, seedArtist: resolvedArtist,
                    mode: mode, selectedGenre: genre, hideLiked: hideLiked,
                    notInterestedTrackIDs: excludedTracks, notInterestedArtistIDs: excludedArtists)
                guard !Task.isCancelled, self.store === store, self.discoveryRequestID == requestID,
                    self.selection.source == .similar
                else { return }
                self.catalog = store.catalog
                self.discoverySnapshot = snapshot
                self.discoverySelectedGenre = snapshot.selectedGenre
                self.listenBrainzStatus = store.listenBrainzStatus
                self.refreshContents()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, self.store === sourceStore,
                    self.discoveryRequestID == requestID
                else { return }
                self.statusMessage = SpotifyStatus.message(error)
            }
        }
    }

    private func applyDiscoveryPreview(_ snapshot: MusicDiscoverySnapshot) {
        discoverySnapshot = snapshot
        discoverySnapshotConsent = listenBrainzEnabled
        if let genre = discoverySelectedGenre, !snapshot.genres.contains(genre) {
            discoverySelectedGenre = nil
            discoverySnapshot?.selectedGenre = nil
        }
    }

    private func discoveryPreviewBuilder(
        seedTitle: String, seedTrack: MusicTrack?, seedArtist: MusicArtist?, sameSeed: Bool
    ) -> @Sendable () -> MusicDiscoverySnapshot {
        let previous = sameSeed && store is SpotifyLibraryStore ? discoverySnapshot : nil
        let cached = (store as? SpotifyLibraryStore)?.cachedDiscoveryBuilder(
            seedTitle: seedTitle, seedTrack: seedTrack, seedArtist: seedArtist,
            mode: discoveryMode, selectedGenre: discoverySelectedGenre,
            hideLiked: discoveryHideLiked, notInterestedTrackIDs: notInterestedTrackIDs,
            notInterestedArtistIDs: notInterestedArtistIDs, previous: previous)
        let mode = discoveryMode
        let genre = discoverySelectedGenre
        let hideLiked = discoveryHideLiked
        let catalog = catalog
        let library = library
        let history = (store as? SpotifyLibraryStore)?.playHistory ?? playHistory
        let excludedTracks = notInterestedTrackIDs
        let excludedArtists = notInterestedArtistIDs
        let genres = sameSeed ? discoverySnapshot?.genres ?? [] : []
        let genreSource = sameSeed ? discoverySnapshot?.genreSource ?? .none : .none
        return {
            if let cached { return cached() }
            if let previous {
                return .init(
                    seed: previous.seed, mode: mode, genres: previous.genres,
                    genreSource: previous.genreSource, selectedGenre: genre, hideLiked: hideLiked,
                    items: previous.items.filter {
                        !(hideLiked && library.likedTrackIDs.contains($0.id))
                            && !excludedTracks.contains($0.id)
                            && !$0.track.artists.contains { excludedArtists.contains($0.id) }
                    }, mixes: previous.mixes)
            }
            return MusicDiscoveryEngine.build(
                seedTitle: seedTitle, seedTrackIDs: seedTrack.map { [$0.id] } ?? [],
                seedArtistIDs: seedArtist.map { [$0.id] } ?? [],
                seedArtistName: seedArtist?.name ?? "", mode: mode, genres: genres,
                genreSource: genreSource, selectedGenre: genre, hideLiked: hideLiked,
                catalog: catalog, library: library, history: history,
                notInterestedTrackIDs: excludedTracks, notInterestedArtistIDs: excludedArtists)
        }
    }

}
