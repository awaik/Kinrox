import Foundation
import RemoteProtocol

extension PlayerSession {
    func wireRemoteLibraryCommands(
        ensurePlayer: @escaping @MainActor () -> Void,
        isTerminating: @escaping @MainActor () -> Bool = { false },
        isFolderAvailable: @escaping @MainActor (WatchedFolder) -> Bool = {
            MediaFolderScanner.isAvailable($0)
        }
    ) {
        remote?.playLibrary = { [weak self] itemId, from, shuffle in
            guard let self, !isTerminating() else { return .internal }
            return self.playRemoteLibrary(
                itemId: itemId, from: from, shuffle: shuffle, ensurePlayer: ensurePlayer,
                isFolderAvailable: isFolderAvailable)
        }
        remote?.resumeSource = { [weak self] source in
            guard let self, !isTerminating() else { return .internal }
            return self.resumeRemoteSource(source, ensurePlayer: ensurePlayer)
        }
    }

    func playRemoteLibrary(
        itemId: String, from: RemotePlaybackStart, shuffle: Bool?,
        ensurePlayer: () -> Void,
        isFolderAvailable: (WatchedFolder) -> Bool = { MediaFolderScanner.isAvailable($0) }
    ) -> ProtocolError.Code? {
        guard let bridge = remote?.libraryBridge else { return .itemNotFound }
        if itemId == RemoteLibraryIDs.allMusic {
            return playAllLocalMusic(
                tracks: bridge.index.tracks, shuffle: shuffle ?? true, ensurePlayer: ensurePlayer,
                isFolderAvailable: isFolderAvailable)
        }
        guard let target = bridge.resolvePlayTarget(itemId) else { return .itemNotFound }
        switch target {
        case .movie(let file, let isOffline, let folder, let isIndexed, let fallbackProgressPath):
            return playRemoteVideo(
                file: file, isOffline: isOffline, folder: folder, isIndexed: isIndexed, from: from,
                fallbackProgressPath: fallbackProgressPath, ensurePlayer: ensurePlayer,
                isFolderAvailable: isFolderAvailable)
        case .episode(let episode, _):
            return playRemoteVideo(
                file: episode.video.file, isOffline: episode.video.isOffline,
                folder: episode.video.folder, isIndexed: true, from: from,
                ensurePlayer: ensurePlayer, isFolderAvailable: isFolderAvailable)
        case .series(let series):
            guard !series.episodes.isEmpty else { return .itemNotFound }
            let available = series.episodes.filter { !$0.video.isOffline }
            guard !available.isEmpty else {
                rescanIfAnyFolderAvailable(
                    series.episodes.compactMap(\.video.folder),
                    isFolderAvailable: isFolderAvailable)
                return .unavailable
            }
            let chosen: RemoteLibraryBridge.IndexedEpisode?
            if from == .start {
                chosen = available.first
            } else {
                chosen =
                    RemoteLibraryBridge.nextEpisode(
                        in: available, progress: mediaLibrary.snapshot.progress)
                    ?? available.first
            }
            guard let chosen else { return .itemNotFound }
            return playRemoteVideo(
                file: chosen.video.file, isOffline: chosen.video.isOffline,
                folder: chosen.video.folder, isIndexed: true, from: from,
                ensurePlayer: ensurePlayer, isFolderAvailable: isFolderAvailable)
        case .album(_, let tracks):
            return playAllLocalMusic(
                tracks: tracks, shuffle: shuffle == true, ensurePlayer: ensurePlayer,
                isFolderAvailable: isFolderAvailable)
        case .track(let entry, let albumTracks):
            if let error = checkFileAvailability(
                url: entry.track.file.url, isOffline: entry.track.isOffline, folder: entry.folder,
                isIndexed: true, isFolderAvailable: isFolderAvailable)
            {
                return error
            }
            if model == nil { ensurePlayer() }
            mode = .video
            if let albumTracks {
                let result = filterPlayableTracks(
                    albumTracks, isFolderAvailable: isFolderAvailable)
                if result.needsRescan { mediaLibrary.rescanAll() }
                if let index = result.playable.firstIndex(where: { $0.id == entry.track.id }) {
                    return localAudio.play(
                        result.playable, at: index, shuffled: shuffle == true, pinSelected: true)
                        ? nil : .internal
                }
            }
            return localAudio.play([entry.track], at: 0, shuffled: false) ? nil : .internal
        }
    }

    func resumeRemoteSource(
        _ source: RemoteControllableSource, ensurePlayer: () -> Void
    ) -> ProtocolError.Code? {
        switch source {
        case .video:
            guard let model, !model.isClosing, model.canControl else { return .noMedia }
            ensurePlayer()
            mode = .video
            model.stopScreensaver()
            if model.paused || model.isAtEnd {
                return model.setPaused(false) ? nil : .internal
            }
            model.returnToVideo()
            return nil
        case .localMusic:
            guard localAudio.currentTrack != nil else { return .noMedia }
            if model == nil { ensurePlayer() }
            model?.stopScreensaver()
            if localAudio.paused && !localAudio.loading {
                return localAudio.setPaused(false) ? nil : .internal
            }
            return nil
        case .spotify:
            guard music.currentTrack != nil, music.acceptsPlayback else { return .noMedia }
            if music.paused, !music.allows("resuming") { return .invalidPayload }
            if model == nil { ensurePlayer() }
            model?.stopScreensaver()
            if music.paused {
                music.setPaused(false)
            }
            return nil
        }
    }

    private func playRemoteVideo(
        file: MediaLibraryFile, isOffline: Bool, folder: WatchedFolder?, isIndexed: Bool,
        from: RemotePlaybackStart, fallbackProgressPath: String? = nil, ensurePlayer: () -> Void,
        isFolderAvailable: (WatchedFolder) -> Bool
    ) -> ProtocolError.Code? {
        if let error = checkFileAvailability(
            url: file.url, isOffline: isOffline, folder: folder, isIndexed: isIndexed,
            isFolderAvailable: isFolderAvailable)
        {
            return error
        }
        ensurePlayer()
        mode = .video
        guard let model, !model.isClosing else { return .internal }
        let sameLoaded =
            model.hasMedia && !model.isLoading
            && model.currentURL.map(VideoFiles.key) == VideoFiles.key(file.url)
        if from == .start {
            if sameLoaded {
                return model.restartFromBeginning() ? nil : .internal
            }
            return model.resume(file.url, from: nil) ? nil : .internal
        }
        if sameLoaded { model.stopScreensaver() }
        let progress =
            mediaLibrary.snapshot.progress[file.path]
            ?? fallbackProgressPath.flatMap { mediaLibrary.snapshot.progress[$0] }
        return model.resume(file.url, from: progress) ? nil : .internal
    }

    private func playAllLocalMusic(
        tracks: [RemoteLibraryBridge.IndexedTrack], shuffle: Bool, ensurePlayer: () -> Void,
        isFolderAvailable: (WatchedFolder) -> Bool
    ) -> ProtocolError.Code? {
        guard !tracks.isEmpty else { return .itemNotFound }
        let online = tracks.filter { !$0.track.isOffline }
        guard !online.isEmpty else {
            rescanIfAnyFolderAvailable(
                tracks.compactMap(\.folder), isFolderAvailable: isFolderAvailable)
            return .unavailable
        }
        let result = filterPlayableTracks(online, isFolderAvailable: isFolderAvailable)
        if result.needsRescan { mediaLibrary.rescanAll() }
        guard !result.playable.isEmpty else {
            return result.sawUnmounted ? .unavailable : .itemNotFound
        }
        if model == nil { ensurePlayer() }
        mode = .video
        return localAudio.play(result.playable, at: 0, shuffled: shuffle) ? nil : .internal
    }

    private func rescanIfAnyFolderAvailable(
        _ folders: [WatchedFolder], isFolderAvailable: (WatchedFolder) -> Bool
    ) {
        var seen: Set<UUID> = []
        for folder in folders where seen.insert(folder.id).inserted {
            if isFolderAvailable(folder) {
                mediaLibrary.rescanAll()
                return
            }
        }
    }

    private func filterPlayableTracks(
        _ tracks: [RemoteLibraryBridge.IndexedTrack], isFolderAvailable: (WatchedFolder) -> Bool
    ) -> (playable: [LocalAudioTrack], sawUnmounted: Bool, needsRescan: Bool) {
        var folderCache: [UUID: Bool] = [:]
        var playable: [LocalAudioTrack] = []
        var sawUnmounted = false
        var needsRescan = false
        for entry in tracks where !entry.track.isOffline {
            if let folder = entry.folder {
                let mounted =
                    folderCache[folder.id]
                    ?? {
                        let available = isFolderAvailable(folder)
                        folderCache[folder.id] = available
                        return available
                    }()
                if !mounted {
                    sawUnmounted = true
                    needsRescan = true
                    continue
                }
            }
            guard FileManager.default.fileExists(atPath: entry.track.file.url.path) else {
                needsRescan = true
                continue
            }
            playable.append(entry.track)
        }
        return (playable, sawUnmounted, needsRescan)
    }

    private func checkFileAvailability(
        url: URL, isOffline: Bool, folder: WatchedFolder?, isIndexed: Bool,
        isFolderAvailable: (WatchedFolder) -> Bool
    ) -> ProtocolError.Code? {
        if isOffline {
            if let folder, isFolderAvailable(folder) { mediaLibrary.rescanAll() }
            return .unavailable
        }
        if let folder, !isFolderAvailable(folder) {
            mediaLibrary.rescanAll()
            return .unavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if isIndexed { mediaLibrary.rescanAll() } else { recents.refreshAvailability() }
            return .itemNotFound
        }
        return nil
    }
}
