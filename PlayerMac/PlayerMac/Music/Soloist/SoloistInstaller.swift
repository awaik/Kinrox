import CryptoKit
import Darwin
import Foundation

struct SoloistInstallation: Codable, Sendable, Equatable {
    let binary: URL
    let digest: String
    let version: String
    let buildDate: Date
    var expiryDate: Date { buildDate.addingTimeInterval(90 * 86_400) }
    func shouldOfferUpdate(at date: Date) -> Bool {
        date >= buildDate.addingTimeInterval(60 * 86_400)
    }
}

private final class SoloistDownloadDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(SoloistInstaller.allowed(request.url) ? request : nil) }
}

/// Opt-in download only. Construction performs no work.
actor SoloistInstaller {
    static let download = URL(
        string: "https://soloist-builds.spotifycdn.com/soloist_release_osx_arm64.tar.gz")!
    static let requirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"2FNC3A47ZF\" and identifier \"com.spotify.soloist\""
    private var installing = false

    nonisolated static func allowed(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == "soloist-builds.spotifycdn.com"
            && url?.user == nil && url?.password == nil && (url?.port == nil || url?.port == 443)
    }

    func install(in directory: URL, now: Date = Date()) async throws -> SoloistInstallation {
        guard !installing else { throw SoloistFailure.installation }
        installing = true
        defer { installing = false }
        let staging = directory.appendingPathComponent("staging-" + UUID().uuidString)
        try Self.privateDirectory(directory)
        // A new, exclusively created directory belongs to this installation attempt only.
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        let archive = staging.appendingPathComponent("distribution.tar.gz")
        guard
            FileManager.default.createFile(
                atPath: archive.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        else { throw SoloistFailure.installation }
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        let session = URLSession(
            configuration: config, delegate: SoloistDownloadDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: Self.download)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            Self.allowed(response.url),
            response.expectedContentLength <= SoloistArchive.maximumBytes
        else { throw SoloistFailure.installation }
        var count = 0
        var chunk = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= SoloistArchive.maximumBytes else { throw SoloistFailure.installation }
            chunk.append(byte)
            if chunk.count == 65_536 {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: chunk)
        try handle.synchronize()
        try handle.close()
        let installation = try await Self.offMain {
            let tar = try Self.utility(
                "/usr/bin/gzip", ["-dc", archive.path], limit: SoloistArchive.maximumBytes)
            try FileManager.default.removeItem(at: archive)
            let binaryData = try SoloistArchive.binary(in: tar)
            try SoloistArchive.validateMachO(binaryData)
            let path = staging.appendingPathComponent("soloist")
            try binaryData.write(to: path, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path.path)
            let digest = SHA256.hash(data: binaryData).map { String(format: "%02x", $0) }.joined()
            try Self.verifySignature(path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: path.path)
            let marker = "0081;" + String(Int(now.timeIntervalSince1970), radix: 16) + ";Kinrox;"
            _ = try Self.utility(
                "/usr/bin/xattr", ["-w", "com.apple.quarantine", marker, path.path])
            let output = try Self.utility(path.path, ["--version"])
            let identity = try Self.identity(output, now: now)
            return SoloistInstallation(
                binary: path, digest: digest, version: identity.0, buildDate: identity.1)
        }
        try Task.checkCancellation()
        let target = directory.appendingPathComponent(
            installation.version + "-" + installation.digest + "-" + UUID().uuidString)
        // Unique, immutable installation slots; never replace an active or unknown directory.
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw SoloistFailure.installation
        }
        let result = SoloistInstallation(
            binary: target.appendingPathComponent("soloist"), digest: installation.digest,
            version: installation.version, buildDate: installation.buildDate)
        try JSONEncoder().encode(result).write(
            to: staging.appendingPathComponent("installation.json"), options: .withoutOverwriting)
        try FileManager.default.moveItem(at: staging, to: target)
        return result
    }

    /// Detached blocking work must finish teardown before its caller releases temporary files.
    nonisolated static func offMain<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await value(of: Task.detached(operation: operation))
    }

    nonisolated static func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.ownerAccountID] as? UInt32 == getuid(),
            values[.type] as? FileAttributeType == .typeDirectory,
            (values[.posixPermissions] as? Int ?? 0) & 0o077 == 0
        else { throw SoloistFailure.installation }
        var url = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try url.setResourceValues(resources)
    }

    nonisolated static func verifySignature(_ binary: URL) throws {
        _ = try utility(
            "/usr/bin/codesign",
            [
                "--verify", "--strict", "--check-notarization",
                "-R=" + requirement, binary.path,
            ])
    }

    nonisolated static func identity(_ data: Data, now: Date) throws -> (String, Date) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SoloistFailure.installation
        }
        let fields = text.split(separator: " ")
        guard fields.count >= 4, fields[0] == "soloist", fields[2] == "build",
            fields[1].allSatisfy({ $0.isNumber || $0 == "." }), fields[1].count < 40,
            let stamp = TimeInterval(fields[3]), stamp.isFinite
        else { throw SoloistFailure.installation }
        let date = Date(timeIntervalSince1970: stamp)
        guard date <= now.addingTimeInterval(86_400), now < date.addingTimeInterval(90 * 86_400)
        else {
            throw SoloistFailure.installation
        }
        return (String(fields[1]), date)
    }

    /// Run only trusted OS utilities or a previously verified binary. Bounded output/deadline.
    /// Call off MainActor. Never use this helper for credential-bearing processes.
    nonisolated static func utility(
        _ executable: String, _ arguments: [String], limit: Int = 16_384
    ) throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                process.terminate()
                for _ in 0..<50 where process.isRunning { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? pipe.fileHandleForReading.close()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var output = Data()
        var eof = false
        while !eof {
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw SoloistFailure.installation
            }
            var descriptor = pollfd(
                fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) >= 0 else { throw SoloistFailure.installation }
            if descriptor.revents != 0 {
                let data = try pipe.fileHandleForReading.read(upToCount: 65_536) ?? Data()
                eof = data.isEmpty
                guard output.count + data.count <= limit else { throw SoloistFailure.installation }
                output.append(data)
            }
        }
        while process.isRunning {
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                throw SoloistFailure.installation
            }
            usleep(10_000)
        }
        guard process.terminationStatus == 0 else { throw SoloistFailure.installation }
        return output
    }
}
