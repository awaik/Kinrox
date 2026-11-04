import Foundation

/// Read-only loopback observation. Counts event types without retaining any payloads.
@main
struct CountFrames {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
            let port = Int(CommandLine.arguments[1]), (1...65535).contains(port),
            let pid = Int32(CommandLine.arguments[2]), pid > 1
        else { throw ProbeError.configuration }
        let check = Process()
        let output = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        check.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN"]
        check.standardOutput = output
        check.standardError = FileHandle.nullDevice
        try check.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        check.waitUntilExit()
        guard check.terminationStatus == 0,
            String(decoding: data, as: UTF8.self).contains("127.0.0.1:\(port)")
        else { throw ProbeError.configuration }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        socket.maximumMessageSize = 65_536
        let counter = Counter()
        socket.resume()
        let reader = Task {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let bytes: Data
                    switch message {
                    case .data(let value): bytes = value
                    case .string(let value): bytes = Data(value.utf8)
                    @unknown default: continue
                    }
                    if let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                        let type = frame["type"] as? String
                    {
                        await counter.record(type)
                    }
                }
            } catch {
                // A bounded read ends by closing its own socket.
            }
        }
        try await Task.sleep(for: .seconds(15))
        socket.cancel(with: .goingAway, reason: nil)
        reader.cancel()
        await reader.value
        session.invalidateAndCancel()
        let result = await counter.counts
        let encoded = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        print(String(decoding: encoded, as: UTF8.self))
    }
    enum ProbeError: Error { case configuration }
    actor Counter {
        var counts: [String: Int] = [:]
        func record(_ type: String) {
            let allowed = [
                "auth_state", "playback_state", "playback_changed", "track_changed",
                "position_sync", "volume_changed", "device_changed", "context_changed",
                "queue_changed", "options_changed", "command_result", "error",
            ]
            counts[allowed.contains(type) ? type : "other", default: 0] += 1
        }
    }
}
