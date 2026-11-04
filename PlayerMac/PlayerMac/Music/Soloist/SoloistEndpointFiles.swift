import Darwin
import Foundation

/// Endpoint artifacts are retired only under the profile lock, after their owner has exited.
/// Preserve unknown files and live PIDs, including a recycled PID belonging to another process.
struct SoloistEndpointFiles: Sendable {
    let profile: URL
    let pid: Int32
    var port: String? = nil
    private static let names = ["ws.addr", "ws.port", "soloist.pid"]

    /// A previous Kinrox process may have died before it could retire its child's endpoint.
    static func retireStale(in profile: URL) throws {
        let present = try read(in: profile)
        guard !present.isEmpty else { return }
        guard let text = present["soloist.pid"]?.text, let pid = Int32(text), pid > 1,
            kill(pid, 0) == -1, errno == ESRCH
        else { throw SoloistFailure.profileBusy }
        try Self(profile: profile, pid: pid).retire()
    }

    func retire() throws {
        let present = try Self.read(in: profile)
        guard !present.isEmpty else { return }
        // An owned child can exit before writing every endpoint file. The namespace was
        // empty before spawn and remains locked until all owned processes have stopped.
        if let value = present["soloist.pid"]?.text, value != String(pid),
            !(port == nil && value.isEmpty)
        {
            throw SoloistFailure.profileBusy
        }
        if let port {
            if let address = present["ws.addr"]?.text, address != "127.0.0.1" {
                throw SoloistFailure.profileBusy
            }
            if let value = present["ws.port"]?.text, value != port {
                throw SoloistFailure.profileBusy
            }
        }
        // Before socket validation the process may have left partially written address/port
        // files. Preserve those bytes too; they are never used to connect to a socket.
        let archive = profile.appendingPathComponent("retired-endpoint-" + UUID().uuidString)
        try SoloistInstaller.privateDirectory(archive)
        // Move the PID last: interrupted retirement can still be recovered on the next launch.
        for name in Self.names {
            guard let file = present[name] else { continue }
            let url = profile.appendingPathComponent(name)
            var current = stat()
            guard lstat(url.path, &current) == 0,
                current.st_dev == file.info.st_dev, current.st_ino == file.info.st_ino,
                current.st_mode == file.info.st_mode, current.st_size == file.info.st_size
            else { throw SoloistFailure.profileBusy }
            try FileManager.default.moveItem(at: url, to: archive.appendingPathComponent(name))
        }
    }

    private static func read(in profile: URL) throws -> [String: (text: String, info: stat)] {
        var result: [String: (text: String, info: stat)] = [:]
        for name in names {
            let path = profile.appendingPathComponent(name).path
            // NONBLOCK also rejects FIFOs without waiting for a writer.
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if descriptor < 0 {
                guard errno == ENOENT else { throw SoloistFailure.profileBusy }
                continue
            }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
                info.st_mode & S_IFMT == S_IFREG, (0...64).contains(info.st_size)
            else { throw SoloistFailure.profileBusy }
            var bytes = [UInt8](repeating: 0, count: 65)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count == info.st_size,
                let text = String(bytes: bytes.prefix(count), encoding: .utf8)
            else { throw SoloistFailure.profileBusy }
            result[name] = (text.trimmingCharacters(in: .whitespacesAndNewlines), info)
        }
        return result
    }
}
