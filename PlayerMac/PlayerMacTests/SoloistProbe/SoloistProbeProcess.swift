import AppKit
import Foundation
import Security

@testable import Kinrox

enum SoloistProbeFailure: Error {
    case configuration, signature, cancelled, invalidKey, keychain, process, endpoint
    case timeout, socket, rejected, spotifyRunning, invalidCommand
}

/// Test-bundle-only harness. Credentials never enter tool output or raw diagnostics.
@MainActor
final class SoloistProbeProcess {
    let root: URL
    let binary: URL
    let deviceName: String
    private var child: Process?
    private var reaper: Process?
    private var lifetime: Pipe?
    var pid: Int32? { child?.isRunning == true ? child?.processIdentifier : nil }
    var exitCode: Int32? { child?.isRunning == false ? child?.terminationStatus : nil }

    init(root: URL, binary: URL) throws {
        self.root = root
        self.binary = binary
        deviceName = "Kinrox Probe " + String(root.lastPathComponent.suffix(6))
        for name in ["profile", "cache"] {
            var directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
    }

    static func key() throws -> String {
        let store = KeychainSpotifyCredentialStore(service: "app.kinrox.spotify.soloist-key")
        if let existing = try store.refreshToken(clientID: "feasibility-probe-v1") {
            return existing
        }
        let alert = NSAlert()
        alert.messageText = "Kinrox — Soloist API Key"
        alert.informativeText =
            "A Spotify Premium subscription is required. Create your personal Soloist API key at https://developer.spotify.com/dashboard/soloist using Open key page below, then paste it here. The key stays in this Mac's Keychain and is passed only to signed Soloist."
        alert.addButton(withTitle: "Save and start probe")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open key page")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 26))
        field.placeholderString = "Soloist API key (not Spotify Client ID)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        var key = ""
        while key.isEmpty {
            let result = alert.runModal()
            if result == .alertThirdButtonReturn {
                NSWorkspace.shared.open(
                    URL(string: "https://developer.spotify.com/dashboard/soloist")!)
                continue
            }
            guard result == .alertFirstButtonReturn else {
                throw SoloistProbeFailure.cancelled
            }
            key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            field.stringValue = ""
            if key.isEmpty {
                alert.informativeText =
                    "The key field is empty. Spotify Premium is required. Use Open key page to visit https://developer.spotify.com/dashboard/soloist, then paste your personal Soloist API key here."
            }
        }
        guard key.utf8.count <= 16_384 else { throw SoloistProbeFailure.invalidKey }
        try store.save(key, clientID: "feasibility-probe-v1")
        return key
    }

    func start(key: String, reaperURL: URL, singleTrack: String? = nil) async throws -> URL {
        guard child?.isRunning != true else { throw SoloistProbeFailure.process }
        let binary = binary
        let valid = await Task.detached {
            var code: SecStaticCode?
            var requirement: SecRequirement?
            let rule =
                "anchor apple generic and certificate leaf[subject.OU] = \"2FNC3A47ZF\" and identifier \"com.spotify.soloist\""
            guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess,
                SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                let code, let requirement
            else { return false }
            return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        }.value
        guard valid else { throw SoloistProbeFailure.signature }
        guard Self.spotifyAbsent else { throw SoloistProbeFailure.spotifyRunning }
        let data = root.appendingPathComponent("profile")
        // Runtime endpoint files must have disappeared after an owned normal shutdown.
        guard !FileManager.default.fileExists(atPath: data.appendingPathComponent("ws.port").path)
        else { throw SoloistProbeFailure.endpoint }
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--device-name", deviceName, "--api-key", key,
            "--data-dir", data.path, "--cache-dir", root.appendingPathComponent("cache").path,
            "--cache-size", "200", "--initial-volume", "0", "--ws", "127.0.0.1:0",
        ]
        if let singleTrack {
            guard
                singleTrack.range(
                    of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil
            else { throw SoloistProbeFailure.invalidCommand }
            process.arguments?.append(contentsOf: ["--single-track", singleTrack])
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        child = process
        let lifetime = Pipe()
        let ready = Pipe()
        let host = Process()
        host.executableURL = reaperURL
        host.arguments = [String(process.processIdentifier), binary.path]
        host.standardInput = lifetime
        host.standardOutput = ready
        host.standardError = FileHandle.nullDevice
        do {
            try host.run()
            try lifetime.fileHandleForReading.close()
            try ready.fileHandleForWriting.close()
            reaper = host
            self.lifetime = lifetime
            let handle = ready.fileHandleForReading
            let received = await Task.detached { try? handle.read(upToCount: 6) }.value
            try? handle.close()
            guard received == Data("READY\n".utf8) else { throw SoloistProbeFailure.process }
            for _ in 0..<200 {
                guard process.isRunning else { throw SoloistProbeFailure.process }
                if let address = try? String(
                    contentsOf: data.appendingPathComponent("ws.addr"), encoding: .utf8),
                    let text = try? String(
                        contentsOf: data.appendingPathComponent("ws.port"), encoding: .utf8),
                    address.trimmingCharacters(in: .whitespacesAndNewlines) == "127.0.0.1",
                    let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                    (1...65535).contains(port)
                {
                    return URL(string: "ws://127.0.0.1:\(port)")!
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw SoloistProbeFailure.timeout
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        try? lifetime?.fileHandleForWriting.close()
        lifetime = nil
        if child?.isRunning == true { child?.terminate() }
        for _ in 0..<100 where child?.isRunning == true || reaper?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    static var spotifyAbsent: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }
}
