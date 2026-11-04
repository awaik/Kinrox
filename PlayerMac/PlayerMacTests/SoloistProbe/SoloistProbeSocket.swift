import Foundation

private final class SoloistProbeRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

/// S0 wire observation only: never infers EOF or occurrence identity from URI alone.
@MainActor
final class SoloistProbeSocket {
    let session: URLSession
    let socket: URLSessionWebSocketTask
    let trace: FileHandle
    let started = ContinuousClock.now
    var receiving: Task<Void, Never>?
    var loggedIn = false
    var active = false
    var status = "unknown"
    var uri: String?
    var position: Double = 0
    var duration: Double = 0
    var volume: Double?
    var revision = 0
    var stateRevision = 0
    private(set) var confirmedPlayingURI: String?
    var acknowledgements = 0
    var errors = 0
    var disconnected = false
    var written = 0
    private var labels: [String: Int] = [:]
    private var queueLabels: [String: Int] = [:]
    static let commands: Set<String> = [
        "get_auth_state", "get_state", "get_queue", "play", "pause", "seek", "set_volume",
        "set_shuffle", "set_repeat_context", "set_repeat_track", "activate", "deactivate",
    ]

    init(url: URL, traceURL: URL) throws {
        guard url.host == "127.0.0.1", url.scheme == "ws" else {
            throw SoloistProbeFailure.endpoint
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        session = URLSession(
            configuration: config, delegate: SoloistProbeRedirect(), delegateQueue: nil)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 65_536
        guard
            FileManager.default.createFile(
                atPath: traceURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw SoloistProbeFailure.configuration }
        trace = try FileHandle(forWritingTo: traceURL)
        socket.resume()
        receiving = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await self?.socket.receive()
                    guard let self, let message else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw SoloistProbeFailure.socket
                    }
                    try self.receive(data)
                } catch {
                    self?.disconnected = true
                    self?.record(["event": "socket_closed"])
                    return
                }
            }
        }
    }

    func receive(_ data: Data) throws {
        guard data.count <= 65_536,
            let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = frame["type"] as? String
        else { throw SoloistProbeFailure.socket }
        let known: Set<String> = [
            "auth_state", "playback_state", "track_changed", "playback_changed", "volume_changed",
            "device_changed", "context_changed", "options_changed", "position_sync",
            "queue_changed",
            "command_result", "error",
        ]
        guard known.contains(type) else {
            record(["event": "unknown"])
            return
        }
        revision += 1
        if type == "playback_state" { stateRevision += 1 }
        if let value = frame["logged_in"] as? Bool { loggedIn = value }
        if let value = frame["is_active"] as? Bool { active = value }
        if let value = frame["status"] as? String,
            ["idle", "playing", "paused", "buffering"].contains(value)
        {
            status = value
        }
        if let value = frame["volume"] as? Double, value.isFinite, (0...100).contains(value) {
            volume = value
        }
        if let item = frame["item"] as? [String: Any] {
            uri = item["uri"] as? String
            let decorations = item["decorations"] as? [String: Any]
            let playback = decorations?["playback"] as? [String: Any]
            duration = playback?["duration_ms"] as? Double ?? 0
            if let uri, !uri.isEmpty, labels[uri] == nil, labels.count < 50 {
                labels[uri] = labels.count + 1
            }
        }
        if let anchor = frame["position"] as? [String: Any],
            let value = anchor["position_ms"] as? Double,
            value.isFinite
        {
            position = value
        }
        if type == "command_result" { acknowledgements += 1 }
        if type == "error" { errors += 1 }
        if ["track_changed", "context_changed"].contains(type)
            || (type == "playback_changed" && status != "playing")
            || (type == "device_changed" && !active)
        {
            confirmedPlayingURI = nil
        }
        if type == "playback_state" {
            let anchor = frame["position"] as? [String: Any]
            confirmedPlayingURI =
                status == "playing" && anchor?["speed"] as? Double == 1
                ? uri.flatMap { $0.isEmpty ? nil : $0 } : nil
        }
        var event = snapshot
        event["event"] = type
        if let command = frame["command"] as? String, Self.commands.contains(command) {
            event["command"] = command
        }
        if let anchor = frame["position"] as? [String: Any],
            let speed = anchor["speed"] as? Double, speed.isFinite
        {
            event["speed"] = speed
        }
        if type == "queue_changed" {
            for section in ["previous", "upcoming"] {
                if let entries = frame[section] as? [[String: Any]] {
                    event[section] = entries.prefix(10).map { entry -> [String: Any] in
                        var result: [String: Any] = [:]
                        if let uid = entry["uid"] as? String, !uid.isEmpty {
                            if queueLabels[uid] == nil, queueLabels.count < 100 {
                                queueLabels[uid] = queueLabels.count + 1
                            }
                            result["entry_label"] = queueLabels[uid]
                        }
                        if let item = entry["item"] as? [String: Any],
                            let uri = item["uri"] as? String, !uri.isEmpty
                        {
                            if labels[uri] == nil, labels.count < 100 {
                                labels[uri] = labels.count + 1
                            }
                            result["item_label"] = labels[uri]
                        }
                        if let source = entry["source"] as? String,
                            ["context", "queue", "autoplay"].contains(source)
                        {
                            result["source"] = source
                        }
                        return result
                    }
                }
            }
        }
        if let options = frame["options"] as? [String: Any] {
            event["shuffle"] = options["shuffle"] as? Bool
            if let mode = options["repeat"] as? String, ["off", "track", "context"].contains(mode) {
                event["repeat"] = mode
            }
        }
        // No names, account IDs, URIs, error text, artwork or untrusted strings reach disk.
        record(event)
    }

    var snapshot: [String: Any] {
        var result: [String: Any] = [
            "logged_in": loggedIn, "active": active, "status": status,
            "position_ms": position, "duration_ms": duration, "revision": revision,
            "acks": acknowledgements, "errors": errors,
        ]
        result["volume"] = volume
        result["item_label"] = uri.flatMap { labels[$0] }
        return result
    }

    func record(_ event: [String: Any]) {
        guard written < 4 * 1024 * 1024 else { return }
        var event = event
        let elapsed = started.duration(to: .now).components
        event["monotonic_seconds"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        else { return }
        data.append(10)
        try? trace.write(contentsOf: data)
        written += data.count
    }

    func send(_ name: String, fields: [String: Any] = [:]) async throws {
        guard Self.commands.contains(name) else { throw SoloistProbeFailure.invalidCommand }
        let allowed: Set<String> = ["uri", "position_ms", "volume", "enabled", "limit"]
        guard Set(fields.keys).isSubset(of: allowed) else {
            throw SoloistProbeFailure.invalidCommand
        }
        var payload = fields
        payload["type"] = "command"
        payload["command"] = name
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SoloistProbeFailure.invalidCommand
        }
        record(["event": "submit", "command": name])
        try await socket.send(.string(text))
    }

    func wait(seconds: Double = 10, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        while !predicate() {
            guard !disconnected else { throw SoloistProbeFailure.socket }
            guard .now < deadline else { throw SoloistProbeFailure.timeout }
            guard SoloistProbeProcess.spotifyAbsent else {
                throw SoloistProbeFailure.spotifyRunning
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        receiving?.cancel()
        receiving = nil
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        try? trace.close()
    }
}
