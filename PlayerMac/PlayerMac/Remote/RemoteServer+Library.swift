import Foundation
import RemoteProtocol

extension RemoteServer {
    static let libraryFeature = "library.v1"

    func connectLibrary(
        _ store: MediaLibraryStore,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        progressCoalesceInterval: TimeInterval = 10
    ) {
        libraryBridge?.disconnect()
        artworkScheduler?.cancelAll()
        let bridge = RemoteLibraryBridge(
            store: store, recents: recents, defaults: defaults, localAudio: localAudio,
            now: now, progressCoalesceInterval: progressCoalesceInterval)
        bridge.isVideoPlaying = { [weak self] in
            guard let model = self?.model else { return false }
            return model.canControl && !model.paused && !model.isAtEnd
        }
        bridge.currentVideoPath = { [weak self] in
            self?.model?.currentURL.map(VideoFiles.key)
        }
        bridge.currentVideoTracks = { [weak self] in
            self?.model?.trackController.tracks ?? []
        }
        bridge.hasConnectedClients = { [weak self] in
            self?.outboxes.isEmpty == false
        }
        bridge.changed = { [weak self] in
            guard let self else { return }
            self.publishSnapshot()
        }
        libraryBridge = bridge
        artworkScheduler = RemoteArtworkScheduler(service: bridge.artworkService)
        syncLocalMusicBridge()
        publishSnapshot(immediate: true)
    }

    func publishSnapshot(immediate: Bool = false) {
        guard !outboxes.isEmpty else { return }
        publisher.update(snapshot, immediate: immediate)
    }

    func syncLocalMusicBridge() {
        localMusicBridge?.disconnect()
        localMusicBridge = nil
        if let localAudioObserver { localAudio?.removePlaybackObserver(localAudioObserver) }
        localAudioObserver = nil
        guard let player = localAudio else { return }
        if let libraryBridge {
            let bridge = RemoteLocalMusicBridge(
                player: player, ids: libraryBridge.ids, serverName: serverName,
                libraryRevision: { [weak libraryBridge] in
                    libraryBridge?.libraryRevision ?? UUID()
                },
                isScreensaverEngaged: { [weak self] in
                    self?.model?.isScreensaverEngaged == true
                })
            bridge.changed = { [weak self] in
                guard let self else { return }
                self.publishSnapshot()
            }
            localMusicBridge = bridge
        } else {
            localAudioObserver = player.observePlayback { [weak self] _ in
                guard let self else { return }
                self.publishSnapshot()
            }
        }
    }

    func projectedState(_ canonical: PlayerState, for connectionId: UUID) -> PlayerState {
        if connectionFeatures[connectionId]?.contains(Self.libraryFeature) == true {
            return canonical
        }
        guard canonical.source == .music, canonical.music?.origin == .local else {
            return canonical
        }
        var legacy = canonical
        legacy.source = .video
        legacy.music = nil
        return legacy
    }

    func broadcastState(_ canonical: PlayerState, force: Bool) {
        for (id, outbox) in Array(outboxes) {
            let projected = projectedState(canonical, for: id)
            if !force, lastSentState[id] == projected { continue }
            lastSentState[id] = projected
            outbox.enqueue(.state(.init(), projected))
        }
    }

    func handleLibraryOrMusicMessage(id: UUID, message: Message) {
        guard let outbox = outboxes[id] else { return }
        switch message {
        case .requestState(_, let request):
            if let features = request.features {
                connectionFeatures[id] = Set(features)
            }
            let projected = projectedState(snapshot, for: id)
            lastSentState[id] = projected
            outbox.enqueue(.state(.init(), projected))
        case .requestQueue(let header, let request):
            if activeLocalAudio != nil {
                if let bridge = localMusicBridge {
                    outbox.enqueue(bridge.queuePage(request, replyTo: header.id))
                } else {
                    outbox.enqueue(errorReply(to: header.id, code: .noMedia))
                }
            } else if let bridge = musicBridge {
                outbox.enqueue(bridge.queuePage(request, replyTo: header.id))
            }
        case .requestLikeOptions(let header, let request):
            if activeLocalAudio != nil {
                outbox.enqueue(errorReply(to: header.id, code: .invalidPayload))
            } else if let bridge = musicBridge {
                outbox.enqueue(bridge.likeOptionsPage(request, replyTo: header.id))
            }
        case .requestLibrary(let header, let request):
            if let bridge = libraryBridge {
                outbox.enqueue(bridge.libraryPage(request, replyTo: header.id))
            } else {
                outbox.enqueue(errorReply(to: header.id, code: .unknownMessage))
            }
        case .requestLibraryItem(let header, let request):
            if let bridge = libraryBridge {
                outbox.enqueue(bridge.itemDetails(request, replyTo: header.id))
            } else {
                outbox.enqueue(errorReply(to: header.id, code: .unknownMessage))
            }
        case .requestArtwork(let header, let request):
            if let bridge = libraryBridge, let scheduler = artworkScheduler {
                scheduler.enqueue(
                    connectionId: id, replyTo: header.id, id: request.id,
                    artworkKey: bridge.artworkKey(for: request.id), maxPixel: request.maxPixel,
                    outbox: outbox)
            } else {
                outbox.enqueue(
                    .artwork(.init(), .init(replyTo: header.id, id: request.id, jpeg: nil)))
            }
        default: break
        }
    }

    private func errorReply(to id: UUID, code: ProtocolError.Code) -> Message {
        .error(.init(), .init(replyTo: id, code: code, message: Self.message(for: code)))
    }
}
