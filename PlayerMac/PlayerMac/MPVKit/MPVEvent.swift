import Foundation

extension PlaybackProperty {
    var mpvFormat: mpv_format {
        switch self {
        case .paused, .endReached, .idle, .buffering: MPV_FORMAT_FLAG
        case .position, .duration, .volume: MPV_FORMAT_DOUBLE
        case .title, .hardwareDecoder, .audioOutput, .audioCodec: MPV_FORMAT_STRING
        case .tracks: MPV_FORMAT_NODE
        }
    }
}

enum MPVEvent {
    // mpv owns event memory only until next wait_event; copies are passed out.
    static func copy(_ event: mpv_event) -> PlaybackEvent? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return nil }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let name = property.name,
                let key = PlaybackProperty(rawValue: String(cString: name))
            else { return nil }
            guard let value = property.data else { return .property(key, .unavailable) }
            switch property.format {
            case MPV_FORMAT_NODE where key == .tracks:
                return .property(
                    key,
                    .tracks(MPVTracks.copy(value.assumingMemoryBound(to: mpv_node.self).pointee)))
            case MPV_FORMAT_FLAG:
                return .property(key, .flag(value.assumingMemoryBound(to: Int32.self).pointee != 0))
            case MPV_FORMAT_DOUBLE:
                return .property(key, .number(value.assumingMemoryBound(to: Double.self).pointee))
            case MPV_FORMAT_STRING:
                let string = value.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                return .property(key, string.map { .text(String(cString: $0)) } ?? .unavailable)
            default: return .property(key, .unavailable)
            }
        case MPV_EVENT_START_FILE: return .started
        case MPV_EVENT_FILE_LOADED: return .loaded
        case MPV_EVENT_SEEK: return .seeking
        case MPV_EVENT_PLAYBACK_RESTART: return .playbackRestarted
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return .ended(error: nil) }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let error =
                end.reason == MPV_END_FILE_REASON_ERROR
                ? MPVError(code: end.error, operation: "Failed to play file").message
                : nil
            return .ended(error: error)
        case MPV_EVENT_COMMAND_REPLY where event.reply_userdata != 0:
            return .trackCommandCompleted(
                id: event.reply_userdata,
                error: event.error < 0
                    ? MPVError(code: event.error, operation: "Track command").message : nil)
        case MPV_EVENT_COMMAND_REPLY where event.error < 0:
            return .failure(MPVError(code: event.error, operation: "Player command").message)
        case MPV_EVENT_QUEUE_OVERFLOW:
            return .failure("Player event queue overflow. Reopen the file.")
        case MPV_EVENT_SHUTDOWN: return .shutdown
        default: return nil
        }
    }
}
