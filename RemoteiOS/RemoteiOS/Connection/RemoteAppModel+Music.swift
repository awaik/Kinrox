import Foundation
import RemoteProtocol
import RemoteTransport

extension RemoteAppModel {
    func musicAllows(_ action: String) -> Bool {
        state.music?.disallowedActions?.contains(action) != true
    }

    enum MusicPageRequest {
        case queue(QueueRequest)
        case options(LikeOptionsRequest)
    }
    var supportsMusic: Bool { hasState && state.source != nil && state.music != nil }

    func musicStateChanged(from previous: PlayerState) {
        if state.music?.status != nil { pendingLikeTrackID = nil }
        guard supportsMusic else {
            resetMusicPages()
            return
        }
        if state.music?.queueRevision != previous.music?.queueRevision, showsMusicQueue {
            requestMusicQueue()
        }
        if state.music?.libraryRevision != previous.music?.libraryRevision,
            let id = likeOptionsTrackID ?? pendingLikeTrackID
        {
            requestLikeOptions(id)
        }
        if let id = pendingLikeTrackID, state.music?.track?.id == id, state.music?.liked == true {
            pendingLikeTrackID = nil
            likeOptionsTrackID = id
            showsLikeOptions = true
            requestLikeOptions(id)
        }
    }

    func requestMusicQueue(offset: Int = 0) {
        guard supportsMusic else { return }
        if isDemo {
            syncMusicDemoPages()
            return
        }
        if offset == 0 {
            musicQueue = []
            queueNextOffset = nil
        }
        sendMusicPage(.queue(.init(offset: offset, revision: offset == 0 ? nil : queueRevision)))
    }
    func requestLikeOptions(_ id: String, offset: Int = 0) {
        guard supportsMusic else { return }
        if isDemo {
            likeOptionsTrackID = id
            syncMusicDemoPages()
            return
        }
        if offset == 0 { likeOptions = [] }
        sendMusicPage(
            .options(
                .init(trackId: id, offset: offset, revision: offset == 0 ? nil : optionsRevision)))
    }
    private func sendMusicPage(_ request: MusicPageRequest) {
        guard controlsEnabled, let client else { return }
        let oldIDs = musicPageRequests.compactMap { id, old -> UUID? in
            switch (request, old) {
            case (.queue, .queue), (.options, .options): id
            default: nil
            }
        }
        for id in oldIDs {
            musicPageRequests[id] = nil
            musicPageTimeouts.removeValue(forKey: id)?.cancel()
        }
        let header = Message.Header()
        let message: Message
        switch request {
        case .queue(let query):
            message = .requestQueue(header, query)
            queueLoading = true
        case .options(let query):
            message = .requestLikeOptions(header, query)
            optionsLoading = true
        }
        musicPageRequests[header.id] = request
        let attempt = epoch
        musicPageTimeouts[header.id] = scheduler.schedule(after: 15) { [weak self] in
            guard let self, self.epoch == attempt else { return }
            self.musicPageRequests[header.id] = nil
            self.musicPageTimeouts[header.id] = nil
            self.queueLoading = false
            self.optionsLoading = false
            self.commandError = L10n.text("Mac did not confirm command. Check player state.")
        }
        tasks[header.id] = Task { [weak self] in
            guard let self, self.epoch == attempt else { return }
            do { try await client.send(message) } catch {
                if self.epoch == attempt {
                    self.connectionLost(error as? TransportFailure ?? .closed)
                }
            }
            self.tasks[header.id] = nil
        }
    }

    func receiveQueue(_ page: QueuePage) {
        guard case .queue(let request) = musicPageRequests.removeValue(forKey: page.replyTo) else {
            return
        }
        musicPageTimeouts.removeValue(forKey: page.replyTo)?.cancel()
        queueLoading = false
        if page.offset == 0 {
            musicQueue = []
            queueRevision = page.revision
        }
        guard page.revision == queueRevision, page.offset == musicQueue.count,
            page.offset == request.offset || page.offset == 0
        else {
            requestMusicQueue()
            return
        }
        musicQueue += page.items
        queueNextOffset = page.nextOffset
    }
    func receiveLikeOptions(_ page: LikeOptionsPage) {
        guard case .options(let request) = musicPageRequests.removeValue(forKey: page.replyTo),
            request.trackId == page.trackId
        else { return }
        musicPageTimeouts.removeValue(forKey: page.replyTo)?.cancel()
        optionsLoading = false
        if page.offset == 0 {
            likeOptions = []
            optionsRevision = page.revision
        }
        guard page.revision == optionsRevision, page.offset == likeOptions.count else {
            requestLikeOptions(page.trackId)
            return
        }
        likeOptions += page.items
        if pendingLikeTrackID == page.trackId, page.liked {
            pendingLikeTrackID = nil
            likeOptionsTrackID = page.trackId
            showsLikeOptions = true
        }
        if let offset = page.nextOffset { requestLikeOptions(page.trackId, offset: offset) }
    }

    func toggleMusicLike(trackId: String, currentlyLiked: Bool) {
        guard supportsMusic else { return }
        if !currentlyLiked { pendingLikeTrackID = trackId }
        send(.setTrackLiked(trackId: trackId, liked: !currentlyLiked)) { [weak self] accepted in
            guard let self else { return }
            if !accepted {
                self.pendingLikeTrackID = nil
            } else if !currentlyLiked {
                self.requestLikeOptions(trackId)
            }
        }
    }
    func setMusicOption(_ option: RemoteLikeOption, selected: Bool) {
        guard let id = likeOptionsTrackID else { return }
        let command: Command =
            option.kind == .playlist
            ? .setPlaylistMembership(trackId: id, playlistId: option.id, included: selected)
            : .setArtistFollowed(artistId: option.id, followed: selected)
        send(command)
    }
    func createMusicPlaylist(_ title: String) {
        guard let id = likeOptionsTrackID else { return }
        send(.createPlaylist(title: title, trackId: id))
    }
    func resetMusicPages() {
        for timeout in musicPageTimeouts.values { timeout.cancel() }
        musicPageTimeouts = [:]
        musicPageRequests = [:]
        musicQueue = []
        likeOptions = []
        queueNextOffset = nil
        queueLoading = false
        optionsLoading = false
        showsLikeOptions = false
        likeOptionsTrackID = nil
        pendingLikeTrackID = nil
    }
}
