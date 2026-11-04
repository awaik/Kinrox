import Darwin
import Foundation

/// One explicitly authorized audition of an already playing, owned app child. Never reads a key.
@main
struct AppAudition {
    static func main() async {
        guard ProcessInfo.processInfo.environment["KINROX_SOLOIST_APP_AUDITION"] == "1",
            CommandLine.arguments.count == 5,
            let port = Int(CommandLine.arguments[1]), (1...65535).contains(port),
            let child = Int32(CommandLine.arguments[2]), child > 1,
            let parent = Int32(CommandLine.arguments[3]), parent > 1
        else {
            print("{\"failed\":true,\"stage\":\"authorization\"}")
            return
        }
        let resources = CommandLine.arguments[4]
        guard let owner = Owner.capture(child: child, parent: parent, resources: resources),
            let listeners = utility(
                "/usr/sbin/lsof",
                ["-nP", "-a", "-p", String(child), "-iTCP:\(port)", "-sTCP:LISTEN"]),
            listeners.contains("127.0.0.1:\(port)")
        else {
            print("{\"failed\":true,\"stage\":\"ownership\"}")
            return
        }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        socket.maximumMessageSize = 65_536
        let observation = Observation()
        socket.resume()
        let reader = Task {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    await observation.receive(data)
                }
            } catch {}
        }
        var watchdog: Task<Void, Never>?
        var madeAudible = false
        do {
            try await wait { await observation.readyAtZero }
            guard owner.stillOwned() else { throw Failure.ownership }
            madeAudible = true
            watchdog = Task.detached {
                do { try await Task.sleep(for: .seconds(7)) } catch { return }
                if await !observation.finished { owner.stopIfOwned() }
            }
            try await send(socket, command: "set_volume", volume: 5)
            try await wait { await observation.volume == 5 }
            let began = ContinuousClock.now
            try await Task.sleep(for: .seconds(5))
            try await send(socket, command: "set_volume", volume: 0)
            try await wait { await observation.volume == 0 }
            let interval = began.duration(to: .now).components
            try await send(socket, command: "pause")
            try await wait { await observation.paused }
            await observation.finish()
            let seconds = Double(interval.seconds) + Double(interval.attoseconds) / 1e18
            print(
                "{\"volume_before\":0,\"volume_during\":5,\"volume_after\":0,\"paused\":true,\"seconds_until_confirmed_zero\":\(seconds)}"
            )
        } catch {
            if madeAudible { owner.stopIfOwned() }
            print("{\"failed\":true,\"owned_child_stop_attempted\":\(madeAudible)}")
        }
        watchdog?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        reader.cancel()
        await reader.value
        session.invalidateAndCancel()
    }

    static func send(_ socket: URLSessionWebSocketTask, command: String, volume: Int? = nil)
        async throws
    {
        var value: [String: Any] = ["type": "command", "command": command]
        if let volume { value["volume"] = volume }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    static func wait(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    enum Failure: Error { case ownership, timeout }

    actor Observation {
        var volume: Int?
        var paused = true
        var playing = false
        var active = false
        var loggedIn = false
        var finished = false
        var readyAtZero: Bool { volume == 0 && playing && active && loggedIn }
        func finish() { finished = true }
        func receive(_ data: Data) {
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if let value = value["volume"] as? Int { volume = value }
            if let value = value["status"] as? String {
                paused = value == "paused"
                playing = value == "playing"
            }
            if let value = value["is_active"] as? Bool { active = value }
            if let value = value["logged_in"] as? Bool { loggedIn = value }
        }
    }

    struct Owner: Sendable {
        let child: Int32
        let parent: Int32
        let start: UInt64
        let resources: String
        static func capture(child: Int32, parent: Int32, resources: String) -> Self? {
            guard let text = utility(resources, [String(child)]),
                let data = text.data(using: .utf8),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let start = value["start_ticks"] as? UInt64
            else { return nil }
            let owner = Self(child: child, parent: parent, start: start, resources: resources)
            return owner.stillOwned() ? owner : nil
        }
        func stillOwned() -> Bool {
            guard let text = utility(resources, [String(child)]),
                let data = text.data(using: .utf8),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                value["start_ticks"] as? UInt64 == start,
                utility("/bin/ps", ["-p", String(child), "-o", "ppid="])?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == String(parent),
                let path = utility("/bin/ps", ["-p", String(child), "-o", "comm="])
            else { return false }
            return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
                .lastPathComponent == "soloist"
        }
        func stopIfOwned() { if stillOwned() { kill(child, SIGKILL) } }
    }

    static func utility(_ path: String, _ arguments: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
