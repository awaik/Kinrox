import CryptoKit
import Darwin
import Foundation
import Security

enum SoloistInput: Sendable {
    case frame(SoloistFrame, epoch: UInt64)
    case exited(Int32, epoch: UInt64)
    case disconnected(epoch: UInt64)
    case protocolFailure(epoch: UInt64)
}

protocol SoloistDriving: Sendable {
    func start(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void)
        async throws
    func replace(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void)
        async throws
    func send(_ command: SoloistCommand) async throws
    func stop() async
    func close() async
}

extension SoloistDriving {
    func replace(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        await stop()
        try await start(uri: uri, epoch: epoch, receive: receive)
    }
}

private final class SoloistSocketDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

/// Owns the profile lock, exact child handles and bounded socket. No raw output is persisted.
actor SoloistProcessSupervisor: SoloistDriving {
    struct Configuration: Sendable {
        let installation: SoloistInstallation
        let profile: URL
        let cache: URL
        let reaper: URL
        let hostRequirement: String
        let deviceName: String
        let key: @Sendable () async throws -> String
    }
    private let config: Configuration
    private var child: Process?
    private var reaper: Process?
    private var lifetime: Pipe?
    private var lock: Int32 = -1
    private var generation: UInt64 = 0
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var closed = false
    private var stopping = false
    private var launching = false
    private var ownedEndpoint: SoloistEndpointFiles?

    init(config: Configuration) { self.config = config }

    func processID() -> Int32? { child?.isRunning == true ? child?.processIdentifier : nil }

    nonisolated static func hostRequirement(appURL: URL, identifier: String) throws -> String {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let info = information as? [String: Any],
            let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
            team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
            identifier.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
        else { throw SoloistFailure.signature }
        return "anchor apple generic and certificate leaf[subject.OU] = \"" + team
            + "\" and identifier \"" + identifier + "\""
    }

    func start(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        guard uri.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil
        else { throw SoloistFailure.invalidCommand }
        try await launch(arguments: ["--single-track", uri], epoch: epoch, receive: receive)
    }

    func replace(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        guard uri.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil
        else { throw SoloistFailure.invalidCommand }
        try await launch(
            arguments: ["--single-track", uri], epoch: epoch, replacing: true, receive: receive)
    }

    /// Explicit setup only. Pair mode replaces the stored session; idle mode only restores it.
    func startSetup(
        replaceSession: Bool, epoch: UInt64,
        receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        try await launch(
            arguments: replaceSession ? ["--pair"] : [], epoch: epoch, receive: receive)
    }

    private func launch(
        arguments: [String], epoch: UInt64, replacing: Bool = false,
        receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        guard !closed, !launching, !stopping || replacing, replacing || child?.isRunning != true,
            Date() < config.installation.expiryDate
        else { throw SoloistFailure.unavailable }
        launching = true
        defer { launching = false }
        let config = config
        let verificationStart = ContinuousClock.now
        let verification = Task.detached {
            let bytes = try Data(contentsOf: config.installation.binary, options: .mappedIfSafe)
            guard bytes.count <= SoloistArchive.maximumBytes else {
                throw SoloistFailure.installation
            }
            guard
                SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                    == config.installation.digest
            else { throw SoloistFailure.signature }
            try SoloistArchive.validateMachO(bytes)
            try SoloistInstaller.verifySignature(config.installation.binary)
            _ = try SoloistInstaller.utility(
                "/usr/bin/codesign",
                [
                    "--verify", "--strict",
                    "-R=" + config.hostRequirement, config.reaper.path,
                ])
            SoloistTiming.record(.verification, since: verificationStart)
        }
        async let credential: String = {
            let start = ContinuousClock.now
            let key = try await config.key()
            SoloistTiming.record(.credentialRead, since: start)
            return key
        }()
        // Verification and Keychain access may overlap teardown, but audio processes never do.
        if replacing { await stop() }
        generation &+= 1
        let attempt = generation
        defer { verification.cancel() }
        try await SoloistInstaller.value(of: verification)
        let key = try await credential
        guard attempt == generation, !closed, !Task.isCancelled else { throw SoloistFailure.closed }
        guard !key.isEmpty, key.utf8.count <= 16_384 else { throw SoloistFailure.unavailable }
        guard child?.isRunning != true else { throw SoloistFailure.process }
        try acquireProfile()
        try SoloistEndpointFiles.retireStale(in: config.profile)
        let process = Process()
        process.executableURL = config.installation.binary
        process.arguments =
            [
                "--device-name", config.deviceName, "--api-key", key,
                "--data-dir", config.profile.path, "--cache-dir", config.cache.path,
                "--cache-size", "200", "--initial-volume", "0", "--ws", "127.0.0.1:0",
            ] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationReason == .exit ? process.terminationStatus : -1
            Task {
                await self?.childExited(process)
                await receive(.exited(status, epoch: epoch))
            }
        }
        let spawnStart = ContinuousClock.now
        try process.run()
        child = process
        ownedEndpoint = .init(profile: config.profile, pid: process.processIdentifier)
        do {
            try await attachReaper(to: process)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var endpoint: URL?
            while endpoint == nil {
                guard attempt == generation, !closed, process.isRunning else {
                    throw SoloistFailure.process
                }
                try Task.checkCancellation()
                if let address = try? endpointFile("ws.addr"),
                    let port = try? endpointFile("ws.port"),
                    let pid = try? endpointFile("soloist.pid"), address == "127.0.0.1",
                    pid == String(process.processIdentifier), let value = Int(port),
                    (1...65535).contains(value)
                {
                    let actual = try await SoloistInstaller.offMain {
                        try SoloistInstaller.utility(
                            "/usr/sbin/lsof",
                            [
                                "-n", "-P", "-a", "-p",
                                String(process.processIdentifier), "-iTCP:" + port, "-sTCP:LISTEN",
                                "-Fn",
                            ])
                    }
                    guard attempt == generation, !closed, process.isRunning else {
                        throw SoloistFailure.closed
                    }
                    guard
                        String(data: actual, encoding: .utf8)?.split(separator: "\n").contains(
                            "n127.0.0.1:" + port) == true
                    else { throw SoloistFailure.endpoint }
                    ownedEndpoint = .init(
                        profile: config.profile, pid: process.processIdentifier, port: port)
                    endpoint = URL(string: "ws://127.0.0.1:" + port)
                }
                guard ContinuousClock.now < deadline else { throw SoloistFailure.endpoint }
                if endpoint == nil { try await Task.sleep(for: .milliseconds(25)) }
            }
            guard attempt == generation, !closed, let endpoint else { throw SoloistFailure.closed }
            let settings = URLSessionConfiguration.ephemeral
            settings.connectionProxyDictionary = [:]
            settings.httpCookieStorage = nil
            settings.urlCache = nil
            settings.timeoutIntervalForRequest = 5
            let session = URLSession(
                configuration: settings, delegate: SoloistSocketDelegate(), delegateQueue: nil)
            let socket = session.webSocketTask(with: endpoint)
            socket.maximumMessageSize = 65_536
            self.session = session
            self.socket = socket
            socket.resume()
            SoloistTiming.record(.spawnToSocket, since: spawnStart)
            receiver = Task {
                do {
                    while !Task.isCancelled {
                        let data: Data
                        switch try await socket.receive() {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: throw SoloistFailure.invalidFrame
                        }
                        await receive(.frame(try SoloistFrame.decode(data), epoch: epoch))
                    }
                } catch {
                    if !Task.isCancelled {
                        await receive(
                            error as? SoloistFailure == .invalidFrame
                                ? .protocolFailure(epoch: epoch) : .disconnected(epoch: epoch))
                    }
                }
            }
        } catch {
            if attempt == generation { await stop() }
            throw error
        }
    }

    func send(_ command: SoloistCommand) async throws {
        guard let socket, child?.isRunning == true, !closed else { throw SoloistFailure.closed }
        let bytes = try command.encoded()
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SoloistFailure.invalidCommand
        }
        try await socket.send(.string(text))
    }

    func stop() async {
        let stopStart = ContinuousClock.now
        defer { SoloistTiming.record(.stop, since: stopStart) }
        if stopping {
            while stopping { await Self.teardownTick() }
            return
        }
        stopping = true
        defer { stopping = false }
        generation &+= 1
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        try? lifetime?.fileHandleForWriting.close()
        lifetime = nil
        let process = child
        let host = reaper
        if process?.isRunning == true { process?.terminate() }
        for _ in 0..<100 where process?.isRunning == true || host?.isRunning == true {
            await Self.teardownTick()
        }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if let host, host.isRunning { host.terminate() }
        // Keep handles until termination; a new start never overlaps the previous child.
        for _ in 0..<100 where process?.isRunning == true {
            await Self.teardownTick()
        }
        if process?.isRunning != true {
            // Ownership starts at spawn, even if socket validation never completed.
            try? ownedEndpoint?.retire()
            ownedEndpoint = nil
            child = nil
            reaper = nil
        }
    }

    /// Teardown must retain its grace period even when its initiating command was cancelled.
    private static func teardownTick() async {
        await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
    }

    func close() async {
        closed = true
        await stop()
        if lock >= 0 {
            flock(lock, LOCK_UN)
            Darwin.close(lock)
            lock = -1
        }
    }

    private func acquireProfile() throws {
        guard lock < 0 else { return }
        try SoloistInstaller.privateDirectory(config.profile)
        try SoloistInstaller.privateDirectory(config.cache)
        let file = config.profile.appendingPathComponent("kinrox.lock").path
        let descriptor = open(file, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SoloistFailure.profileBusy }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG, flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            Darwin.close(descriptor)
            throw SoloistFailure.profileBusy
        }
        lock = descriptor
    }

    private func endpointFile(_ name: String) throws -> String {
        let file = config.profile.appendingPathComponent(name).path
        let descriptor = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SoloistFailure.endpoint }
        defer { Darwin.close(descriptor) }
        var info = stat()
        var bytes = [UInt8](repeating: 0, count: 65)
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64
        else { throw SoloistFailure.endpoint }
        let size = read(descriptor, &bytes, 65)
        guard (1...64).contains(size), let text = String(bytes: bytes.prefix(size), encoding: .utf8)
        else { throw SoloistFailure.endpoint }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attachReaper(to process: Process) async throws {
        var identity = proc_bsdinfo()
        guard
            proc_pidinfo(
                process.processIdentifier, PROC_PIDTBSDINFO, 0, &identity,
                Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
            identity.pbi_uid == getuid(), identity.pbi_ppid == getpid()
        else { throw SoloistFailure.process }
        let lifetime = Pipe()
        let ready = Pipe()
        let host = Process()
        host.executableURL = config.reaper
        host.arguments = [
            String(process.processIdentifier), config.installation.binary.path,
            String(identity.pbi_start_tvsec), String(identity.pbi_start_tvusec),
        ]
        host.standardInput = lifetime
        host.standardOutput = ready
        host.standardError = FileHandle.nullDevice
        host.terminationHandler = { [weak self] ended in
            Task {
                await self?.reaperExited(pid: ended.processIdentifier, child: process)
            }
        }
        try host.run()
        self.reaper = host
        self.lifetime = lifetime
        try lifetime.fileHandleForReading.close()
        try ready.fileHandleForWriting.close()
        let handle = ready.fileHandleForReading
        let valid = await Task.detached {
            defer { try? handle.close() }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 1000) > 0 else { return false }
            return (try? handle.read(upToCount: 6)) == Data("READY\n".utf8)
        }.value
        guard valid else { throw SoloistFailure.process }
    }

    private func reaperExited(pid: Int32, child process: Process) async {
        guard !closed, !stopping, reaper?.processIdentifier == pid,
            child === process, process.isRunning
        else { return }
        // An old helper's delayed exit cannot stop a replacement. Without our current
        // parent-death guard, retire audio immediately rather than leave it unprotected.
        await stop()
    }

    private func childExited(_ process: Process) async {
        guard child === process, !stopping else { return }
        await stop()
    }
}
