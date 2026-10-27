import Foundation
import Network
import RemoteProtocol
import os

/// All NWConnection callbacks execute on .main. One receive and one send
/// of application message at a time; receive waits for finish processing before reading further.
@MainActor final class WebSocketPeer {
    enum Role { case client, server }
    var onReady: (() async -> Void)?
    var onData: ((Data) async -> Void)?
    var onTick: (() async -> Void)?
    var onClose: ((TransportFailure) -> Void)?
    private(set) var isReady = false
    private(set) var isClosed = false
    private let connection: NWConnection
    private let permitsEndpoint: (NWEndpoint?) -> Bool
    private var approvedEndpoint: NWEndpoint?
    private let interval: Duration
    private let timeout: Duration
    private var heartbeat: Heartbeat?
    private var handshakeDeadline: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var tickHandler: Task<Void, Never>?
    private var started = false
    private var pending: [Outbound] = []
    private var sending: Outbound?
    private static let logger = Logger(subsystem: "app.kinrox.transport", category: "WebSocket")

    private struct Outbound {
        let id: UUID
        let data: Data
        let completion: CheckedContinuation<Void, any Error>
    }

    init(
        connection: NWConnection, role: Role,
        interval: Duration = TransportConfiguration.pingInterval, timeout: Duration? = nil,
        permitsEndpoint: @escaping (NWEndpoint?) -> Bool = { LocalNetworkPolicy.permits($0) }
    ) {
        self.connection = connection
        self.permitsEndpoint = permitsEndpoint
        self.interval = interval
        self.timeout =
            timeout
            ?? (role == .client
                ? TransportConfiguration.clientTimeout : TransportConfiguration.serverTimeout)
    }

    func start() {
        guard !started, !isClosed else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }
        connection.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.pathChanged(status: path.status, endpoint: path.remoteEndpoint)
            }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            MainActor.assumeIsolated {
                if let self, self.isReady, !viable { self.close(.closed) }
            }
        }
        connection.start(queue: .main)
        let startedAt = ContinuousClock.now
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !self.isClosed else { return }
                if !self.isReady {
                    if startedAt.duration(to: .now) >= self.timeout { self.close(.timeout) }
                    continue
                }
                if let deadline = self.handshakeDeadline, ContinuousClock.now >= deadline {
                    self.close(.timeout)
                    return
                }
                switch self.heartbeat?.tick(at: .now) {
                case .timeout: self.close(.timeout)
                case .ping: self.ping()
                default: break
                }
                if !self.isClosed, self.tickHandler == nil {
                    // PIN timeout processing may await send; heartbeat continues
                    // counting and will cancel stalled send regardless of this callback.
                    self.tickHandler = Task { [weak self] in
                        await self?.onTick?()
                        self?.tickHandler = nil
                    }
                }
            }
        }
    }

    /// Network handshake progress is not prolonged by ping/pong or error frames.
    /// nil leaves PIN control to the state machine with its separate 120s timeout.
    func expectHandshakeProgress(within timeout: Duration?) {
        handshakeDeadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
    }

    func pathChanged(status: NWPath.Status, endpoint: NWEndpoint?) {
        guard isReady, !isClosed else { return }
        if let failure = pathFailure(status: status, endpoint: endpoint) {
            close(failure)
        }
    }

    private func pathFailure(status: NWPath.Status?, endpoint: NWEndpoint?)
        -> TransportFailure?
    {
        // A path update can temporarily lack a usable, resolved route. Close it
        // without granting access, but let the client retry discovery and connection.
        guard status == .satisfied, case .hostPort(let host, _) = endpoint else {
            return .notConnected
        }
        switch host {
        case .name: return .notConnected
        case .ipv4, .ipv6:
            if permitsEndpoint(endpoint) { return nil }
            // The same socket can lose its subnet before NWPath becomes unsatisfied.
            // Close it and retry; a new connection must pass the policy again.
            return endpoint == approvedEndpoint ? .notConnected : .nonLocalEndpoint
        @unknown default: return .nonLocalEndpoint
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        guard !isClosed else { return }
        switch state {
        case .ready:
            guard !isReady else { return }
            let path = connection.currentPath
            if let failure = pathFailure(status: path?.status, endpoint: path?.remoteEndpoint) {
                close(failure)
                return
            }
            approvedEndpoint = path?.remoteEndpoint
            isReady = true
            heartbeat = Heartbeat(now: .now, interval: interval, timeout: timeout)
            reader = Task { [weak self] in
                await self?.onReady?()
                self?.receiveNext()
            }
        case .waiting(let error), .failed(let error): close(.network(error))
        case .cancelled: close(.closed)
        default: break
        }
    }

    func send(_ data: Data, id: UUID = UUID()) async throws {
        if Task.isCancelled {
            close(.closed)
            throw CancellationError()
        }
        guard isReady, !isClosed else { throw TransportFailure.notConnected }
        guard data.count <= Codec.maxMessageBytes else {
            close(.messageTooLarge)
            throw TransportFailure.messageTooLarge
        }
        // Bounded queue of current connection. Upon disconnect its contents are not retried.
        guard pending.count < 32 else {
            close(.backpressure)
            throw TransportFailure.backpressure
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                pending.append(Outbound(id: id, data: data, completion: completion))
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSend(id: id) }
        }
    }

    func cancelSend(id: UUID) {
        guard sending?.id == id || pending.contains(where: { $0.id == id }) else { return }
        close(.closed)
    }

    private func pump() {
        guard !isClosed, sending == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        sending = item
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: item.id.uuidString, metadata: [metadata])
        connection.send(
            content: item.data, contentContext: context, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed, self.sending?.id == item.id else { return }
                    if let error {
                        self.close(.network(error))
                        return
                    }
                    self.sending = nil
                    item.completion.resume()
                    self.pump()
                }
            })
    }

    private func receiveNext() {
        guard isReady, !isClosed else { return }
        connection.receiveMessage { [weak self] data, context, complete, error in
            MainActor.assumeIsolated {
                self?.received(data, context: context, complete: complete, error: error)
            }
        }
    }

    func received(
        _ data: Data?, context: NWConnection.ContentContext?, complete: Bool, error: NWError?
    ) {
        guard !isClosed else { return }
        if let error {
            close(.network(error))
            return
        }
        if data == nil, context == nil {
            close(.closed)
            return
        }
        // Network.framework terminates TCP with empty final context without WS metadata.
        // This is EOF; non-empty data and normal contexts still undergo strict validation.
        if data == nil, context?.isFinal == true,
            context?.protocolMetadata(definition: NWProtocolWebSocket.definition) == nil
        {
            close(.closed)
            return
        }
        guard
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata,
            complete
        else {
            close(.invalidMessage)
            return
        }
        switch metadata.opcode {
        case .binary:
            let data = data ?? Data()
            guard data.count <= Codec.maxMessageBytes else {
                close(.messageTooLarge)
                return
            }
            heartbeat?.received(at: .now)
            reader = Task { [weak self] in
                await self?.onData?(data)
                self?.receiveNext()
            }
        case .ping, .pong:
            heartbeat?.received(at: .now)
            receiveNext()
        case .close: close(.closed)
        default: close(.invalidMessage)
        }
    }

    private func ping() {
        guard !isClosed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let error {
                    self.close(.network(error))
                } else {
                    self.heartbeat?.received(at: .now)
                }
            }
        }
        let context = NWConnection.ContentContext(identifier: "heartbeat", metadata: [metadata])
        connection.send(
            content: Data(), contentContext: context, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated { if let error { self?.close(.network(error)) } }
            })
    }

    func close(_ failure: TransportFailure = .closed) {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        timer?.cancel()
        reader?.cancel()
        tickHandler?.cancel()
        connection.cancel()
        let completions = pending.map(\.completion) + (sending.map { [$0.completion] } ?? [])
        pending.removeAll()
        sending = nil
        for completion in completions { completion.resume(throwing: failure) }
        Self.logger.debug("WebSocket connection closed.")
        onClose?(failure)
        onReady = nil
        onData = nil
        onTick = nil
        onClose = nil
    }

    deinit {
        timer?.cancel()
        reader?.cancel()
        tickHandler?.cancel()
        connection.cancel()
    }
}
