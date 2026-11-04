import Foundation

protocol SoloistSetupDriving: SoloistDriving {
    func startSetup(
        replaceSession: Bool, epoch: UInt64,
        receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws
}

extension SoloistProcessSupervisor: SoloistSetupDriving {}

/// Pair and verify the Web API account before making this profile available for playback.
/// No passwords, Web API tokens or account identifiers cross the native socket.
actor SoloistPairing {
    private let driver: any SoloistSetupDriving
    private var epoch: UInt64 = 0
    private var exitCode: Int32?
    private var loggedIn = false
    private var busy = false
    private var cancelled = false

    init(driver: any SoloistSetupDriving) { self.driver = driver }

    func connect(
        replaceSession: Bool, timeout: Double = 180,
        verifyAccount: @Sendable () async throws -> Bool
    ) async throws {
        guard !busy else { throw SoloistFailure.profileBusy }
        busy = true
        cancelled = false
        defer { busy = false }
        do {
            if replaceSession {
                try await start(replaceSession: true)
                try await wait(seconds: timeout) { self.exitCode != nil }
                guard exitCode == 0 else { throw SoloistFailure.unavailable }
                await driver.stop()
            }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            try await start(replaceSession: false)
            try await wait(seconds: 15) { self.loggedIn || self.exitCode != nil }
            guard loggedIn, exitCode == nil else { throw SoloistFailure.unavailable }
            var matched = false
            for _ in 0..<5 {
                try Task.checkCancellation()
                guard !cancelled, exitCode == nil else { throw CancellationError() }
                if try await verifyAccount() {
                    matched = true
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard matched else { throw SoloistFailure.accountMismatch }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            await driver.close()
        } catch {
            await driver.close()
            throw error
        }
    }

    func cancel() async {
        cancelled = true
        epoch &+= 1
        await driver.close()
    }

    private func start(replaceSession: Bool) async throws {
        epoch &+= 1
        exitCode = nil
        loggedIn = false
        try await driver.startSetup(replaceSession: replaceSession, epoch: epoch) { [weak self] in
            await self?.receive($0)
        }
    }

    private func receive(_ input: SoloistInput) {
        switch input {
        case .frame(let frame, let source) where source == epoch:
            if let value = frame.loggedIn { loggedIn = value }
        case .exited(let value, let source) where source == epoch:
            exitCode = value
        default: break
        }
    }

    private func wait(seconds: Double, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw SoloistFailure.observationTimeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
