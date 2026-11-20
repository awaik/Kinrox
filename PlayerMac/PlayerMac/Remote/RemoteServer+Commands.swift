import RemoteProtocol

extension RemoteServer {
    /// Matrix can fail while waiting for pause. Keep its reply pending without blocking
    /// incoming commands, so another phone or Esc can still cancel the start.
    func execute(_ command: Command, completion: @escaping (ProtocolError.Code?) -> Void) {
        guard case .setScreensaver(.matrix) = command else {
            completion(execute(command))
            return
        }
        guard let model, !model.isClosing else {
            completion(.noMedia)
            return
        }
        model.startMatrix { completion($0 ? nil : .internal) }
    }

    /// ack signals accepted command. Confirmed state arrives from engine later.
    func execute(_ command: Command) -> ProtocolError.Code? {
        switch command {
        case .openRecent(let id):
            guard let openRecent else { return .itemNotFound }
            return openRecent(id)
        case .playLibrary(let itemId, let from, let shuffle):
            guard let playLibrary else { return .itemNotFound }
            return playLibrary(itemId, from, shuffle)
        case .resumeSource(let source):
            guard let resumeSource else { return .noMedia }
            return resumeSource(source)
        default: break
        }
        guard let model, !model.isClosing else { return .noMedia }
        if let audio = activeLocalAudio {
            switch command {
            case .toggleFullscreen: return model.toggleFullscreen() ? nil : .internal
            case .setFullscreen(let value): return model.setFullscreen(value) ? nil : .internal
            case .setScreensaver(let value):
                let ok = value == .matrix ? model.startMatrix() : model.stopScreensaver()
                return ok ? nil : .internal
            default: break
            }
            if let localMusicBridge { return localMusicBridge.execute(command) }
            let accepted: Bool
            switch command {
            case .togglePause: accepted = audio.togglePause()
            case .setPaused(let paused): accepted = audio.setPaused(paused)
            case .seekRelative(let seconds): accepted = audio.seek(audio.position + seconds)
            case .seekAbsolute(let seconds): accepted = audio.seek(seconds)
            case .setVolume(let volume): accepted = audio.setVolume(volume)
            case .next:
                guard audio.canNext else { return .itemNotFound }
                accepted = audio.next()
            case .previous:
                guard audio.canPrevious else { return .itemNotFound }
                accepted = audio.previous()
            default: return .unknownMessage
            }
            return accepted ? nil : .internal
        }
        if musicBridge?.active == true {
            switch command {
            case .toggleFullscreen, .setFullscreen, .setScreensaver: break
            default: return musicBridge?.execute(command)
            }
        }
        let accepted: Bool
        switch command {
        case .setScreensaver(let screensaver):
            accepted = screensaver == .matrix ? model.startMatrix() : model.stopScreensaver()
        case .setVolume(let value): accepted = model.setVolume(value)
        case .toggleFullscreen: accepted = model.toggleFullscreen()
        case .setFullscreen(let value): accepted = model.setFullscreen(value)
        default:
            guard model.canControl else { return .noMedia }
            switch command {
            case .togglePause: accepted = model.togglePause()
            case .setPaused(let paused): accepted = model.setPaused(paused)
            case .seekRelative(let seconds): accepted = model.seek(by: seconds)
            case .seekAbsolute(let seconds): accepted = model.seek(to: seconds)
            case .next:
                guard model.canNext else { return .itemNotFound }
                accepted = model.next()
            case .previous:
                guard model.canPrevious else { return .itemNotFound }
                accepted = model.previous()
            default: return .unknownMessage
            }
        }
        return accepted ? nil : .internal
    }

    static func message(for code: ProtocolError.Code) -> String {
        switch code {
        case .noMedia: "Nothing is playing on Mac."
        case .itemNotFound: "File not found."
        case .unavailable: "The drive with this file is not connected."
        default: "Failed to execute command."
        }
    }
}
