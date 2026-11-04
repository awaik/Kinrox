import Foundation

@testable import Kinrox

/// Whitelisted control evidence only. No raw payload, account, URI, key, path or audio.
actor SoloistTraceLog {
    private let file: FileHandle
    private var written = 0
    init(url: URL) throws {
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw SoloistProbeFailure.configuration
        }
        file = try FileHandle(forWritingTo: url)
    }
    func input(_ input: SoloistInput, expectedURI: String) {
        var value: [String: Any] = [:]
        switch input {
        case .frame(let frame, let epoch):
            let types = [
                "auth_state", "playback_state", "playback_changed", "track_changed",
                "volume_changed",
                "device_changed", "context_changed", "options_changed", "position_sync",
                "queue_changed", "command_result", "error",
            ]
            value = ["event": types.contains(frame.type) ? frame.type : "other", "epoch": epoch]
            if let uri = frame.item?.uri { value["matches_occurrence"] = uri == expectedURI }
            if let status = frame.status { value["status"] = status }
            if let active = frame.isActive { value["active"] = active }
            if let loggedIn = frame.loggedIn { value["logged_in"] = loggedIn }
            if let position = frame.position {
                value["position_ms"] = position.positionMS
                value["speed"] = position.speed
            }
            if let volume = frame.volume { value["volume"] = volume }
            if let duration = frame.item?.duration { value["duration"] = duration }
            if let command = frame.command, SoloistCommand.Kind(rawValue: command) != nil {
                value["command"] = command
            }
        case .exited(let code, let epoch): value = ["event": "exit", "code": code, "epoch": epoch]
        case .disconnected(let epoch): value = ["event": "socket_closed", "epoch": epoch]
        case .protocolFailure(let epoch): value = ["event": "protocol_failure", "epoch": epoch]
        }
        write(value)
    }
    func operation(_ name: String) { write(["operation": name]) }
    private func write(_ value: [String: Any]) {
        guard written < 5 * 1024 * 1024 else { return }
        var value = value
        value["time"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        else { return }
        data.append(10)
        written += data.count
        try? file.write(contentsOf: data)
    }
    func close() { try? file.close() }
}

actor SoloistRecordedDriver: SoloistDriving {
    let base: SoloistProcessSupervisor
    let log: SoloistTraceLog
    init(base: SoloistProcessSupervisor, log: SoloistTraceLog) {
        self.base = base
        self.log = log
    }
    func start(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        await log.operation("start")
        let log = log
        try await base.start(uri: uri, epoch: epoch) { input in
            await log.input(input, expectedURI: uri)
            await receive(input)
        }
    }
    func send(_ command: SoloistCommand) async throws {
        await log.operation(command.command.rawValue)
        try await base.send(command)
    }
    func stop() async {
        await log.operation("stop")
        await base.stop()
    }
    func close() async {
        await log.operation("close")
        await base.close()
    }
}
