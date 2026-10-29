import Foundation

/// Copies event-owned C nodes before the next mpv_wait_event call.
enum MPVTracks {
    static func copy(_ node: mpv_node) -> [MediaTrack] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee,
            list.num > 0, let values = list.values
        else { return [] }
        return (0..<Int(list.num)).compactMap { index in
            let item = values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list?.pointee,
                map.num > 0, let keys = map.keys, let values = map.values
            else { return nil }
            var fields: [String: mpv_node] = [:]
            for i in 0..<Int(map.num) {
                if let key = keys[i] { fields[String(cString: key)] = values[i] }
            }
            func string(_ key: String) -> String {
                guard let value = fields[key], value.format == MPV_FORMAT_STRING,
                    let pointer = value.u.string
                else { return "" }
                return String(cString: pointer)
            }
            func flag(_ key: String) -> Bool {
                guard let value = fields[key], value.format == MPV_FORMAT_FLAG else { return false }
                return value.u.flag != 0
            }
            guard let kind = MediaTrackKind(rawValue: string("type")),
                let id = fields["id"], id.format == MPV_FORMAT_INT64, id.u.int64 > 0
            else { return nil }
            var track = MediaTrack(number: id.u.int64, kind: kind)
            track.title = string("title")
            track.language = string("lang")
            track.codec = string("codec")
            if let channels = fields["demux-channel-count"], channels.format == MPV_FORMAT_INT64 {
                track.channels = Int(clamping: channels.u.int64)
            }
            track.isDefault = flag("default")
            track.isForced = flag("forced")
            track.isSelected = flag("selected")
            let filename = string("external-filename")
            if flag("external"), !filename.isEmpty {
                track.externalURL = URL(fileURLWithPath: filename).standardizedFileURL
            }
            return track
        }
    }

    /// Runs on the event thread after FILE_LOADED; the UI receives only Swift values.
    static func loadedSnapshot(handle: OpaquePointer) -> PlaybackEvent? {
        guard let path = mpv_get_property_string(handle, "path") else { return nil }
        defer { mpv_free(path) }
        var node = mpv_node()
        guard mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &node) >= 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }
        return .tracksLoaded(path: String(cString: path), tracks: copy(node))
    }
}
