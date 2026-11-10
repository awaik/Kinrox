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
    private func persistNotInterested() {
        defaults?.set(
            notInterestedTrackIDs.sorted(), forKey: "app.kinrox.music.notInterestedTracks")
        defaults?.set(
            notInterestedArtistIDs.sorted(), forKey: "app.kinrox.music.notInterestedArtists")
        refreshDiscovery()
    }

    func refreshDiscovery() {
        // The setter refreshes Similar itself; avoid launching a second request when it changes.
        if synchronizeDiscoveryConsent(), selection.source == .similar { return }
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
        let cached = (store as? SpotifyLibraryStore)?.cachedDiscovery(
            seedTitle: seedTitle, seedTrack: seedTrack, seedArtist: seedArtist,
            mode: discoveryMode, selectedGenre: discoverySelectedGenre,
            hideLiked: discoveryHideLiked,
            notInterestedTrackIDs: notInterestedTrackIDs,
            notInterestedArtistIDs: notInterestedArtistIDs,
            previous: sameSeed ? discoverySnapshot : nil)
        let previous = sameSeed && store is SpotifyLibraryStore ? discoverySnapshot : nil
        discoverySnapshot =
            cached
            ?? MusicDiscoveryEngine.build(
                seedTitle: seedTitle, seedTrackIDs: seedTrack.map { [$0.id] } ?? [],
                seedArtistIDs: seedArtist.map { [$0.id] } ?? [],
                seedArtistName: seedArtist?.name ?? "",
                mode: discoveryMode, genres: sameSeed ? discoverySnapshot?.genres ?? [] : [],
                genreSource: sameSeed ? discoverySnapshot?.genreSource ?? .none : .none,
                selectedGenre: discoverySelectedGenre, hideLiked: discoveryHideLiked,
                catalog: catalog,
                library: library,
                history: (store as? SpotifyLibraryStore)?.playHistory ?? playHistory,
                notInterestedTrackIDs: notInterestedTrackIDs,
                notInterestedArtistIDs: notInterestedArtistIDs)
        if cached == nil, let previous {
            discoverySnapshot = .init(
                seed: previous.seed, mode: discoveryMode, genres: previous.genres,
                genreSource: previous.genreSource, selectedGenre: discoverySelectedGenre,
                hideLiked: discoveryHideLiked,
                items: previous.items.filter {
                    !(discoveryHideLiked && library.likedTrackIDs.contains($0.id))
                        && !notInterestedTrackIDs.contains($0.id)
                        && notInterestedArtistIDs.isDisjoint(with: $0.track.artists.map(\.id))
                }, mixes: previous.mixes)
        }
        discoverySnapshotConsent = listenBrainzEnabled
        if let genre = discoverySelectedGenre, discoverySnapshot?.genres.contains(genre) != true {
            discoverySelectedGenre = nil
            discoverySnapshot?.selectedGenre = nil
        }
        refreshContents()
        guard let store = store as? SpotifyLibraryStore, store.isConnected else {
            discoveryHasConnectedRefresh = false
            isDiscovering = false
            return
        }
        store.setListenBrainzEnabled(listenBrainzEnabled)
        isDiscovering = true
        discoveryHasConnectedRefresh = true
        let mode = discoveryMode
        let genre = discoverySelectedGenre
        let hideLiked = discoveryHideLiked
        let excludedTracks = notInterestedTrackIDs
        let excludedArtists = notInterestedArtistIDs
        browsingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.store === store, self.discoveryRequestID == requestID {
                    self.isDiscovering = false
                }
            }
            do {
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
                guard !Task.isCancelled, self.store === store, self.discoveryRequestID == requestID
                else { return }
                self.statusMessage = SpotifyStatus.message(error)
            }
        }
    }
}
