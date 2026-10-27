import Foundation
import Network
import RemoteProtocol

/// Network server with no dependencies on player, UI, or Keychain.
@MainActor public final class TransportServer {
    public enum State: Equatable {
        case stopped, starting
        case ready(port: UInt16)
        case waiting(NWError)
        case failed(TransportFailure)
    }
    public enum Event {
        case pairingRequested(connectionId: UUID, device: Message.Hello, pin: String)
        case authenticated(connectionId: UUID, device: Message.Hello)
        case message(connectionId: UUID, Message)
        case disconnected(connectionId: UUID, TransportFailure)
    }
    public private(set) var state = State.stopped
    public var onStateChange: ((State) -> Void)?
    public var onEvent: ((Event) -> Void)?
    public var connectionCount: Int { sessions.count }
    private let advertisement: BonjourAdvertiser
    private let loadToken: (UUID) throws -> Data?
    private let saveToken: (ServerHandshake.PairingRecord) throws -> Void
    private let pairingGate = PairingGate()
    private var listener: NWListener?
    private var sessions: [UUID: ServerSession] = [:]

    public init(
        advertisement: BonjourAdvertiser, loadToken: @escaping (UUID) throws -> Data?,
        saveToken: @escaping (ServerHandshake.PairingRecord) throws -> Void
    ) {
        self.advertisement = advertisement
        self.loadToken = loadToken
        self.saveToken = saveToken
    }

    public func start() throws { try start(advertise: true, loopbackOnly: false) }

    // Localhost tests do not advertise service on real network.
    func start(advertise: Bool, loopbackOnly: Bool) throws {
        guard listener == nil else { return }
        let parameters = TransportConfiguration.parameters(listener: true)
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        }
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        if advertise { listener.service = advertisement.service }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                self.listenerStateChanged(state)
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener,
                    self.sessions.count < TransportConfiguration.maximumClients
                else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
        setState(.starting)
        listener.start(queue: .main)
    }

    func listenerStateChanged(_ state: NWListener.State) {
        guard let listener else { return }
        switch state {
        case .ready:
            guard let port = listener.port else {
                self.fail(.invalidService)
                return
            }
            self.setState(.ready(port: port.rawValue))
        case .waiting(let error): self.setState(.waiting(error))
        case .failed(let error): self.fail(.network(error))
        case .cancelled: self.stop()
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = ServerSession(
            connection: connection, advertisement: advertisement,
            gate: pairingGate, loadToken: loadToken, saveToken: saveToken)
        sessions[session.id] = session
        session.onPairing = { [weak self] id, device, pin in
            self?.onEvent?(.pairingRequested(connectionId: id, device: device, pin: pin))
        }
        session.onAuthenticated = { [weak self] id, device in
            self?.onEvent?(.authenticated(connectionId: id, device: device))
        }
        session.onMessage = { [weak self] id, message in
            self?.onEvent?(.message(connectionId: id, message))
        }
        session.onClosed = { [weak self] id, failure in
            self?.sessions.removeValue(forKey: id)
            self?.onEvent?(.disconnected(connectionId: id, failure))
        }
        session.peer.start()
    }

    public func send(_ message: Message, to connectionId: UUID) async throws {
        guard let session = sessions[connectionId] else { throw TransportFailure.notConnected }
        try await session.send(message)
    }

    public func rejectPairing(connectionId: UUID) {
        sessions[connectionId]?.rejectPairing()
    }

    public func disconnect(connectionId: UUID) { sessions[connectionId]?.close() }

    /// Access revocation includes in-progress handshakes for this device.
    public func disconnect(deviceId: UUID) {
        for session in Array(sessions.values) where session.deviceId == deviceId { session.close() }
    }

    public func stop() {
        closeResources()
        setState(.stopped)
    }

    private func closeResources() {
        let previous = listener
        listener = nil
        previous?.cancel()
        for session in Array(sessions.values) { session.close() }
        sessions.removeAll()
    }

    private func fail(_ failure: TransportFailure) {
        closeResources()
        setState(.failed(failure))
    }

    private func setState(_ state: State) {
        self.state = state
        onStateChange?(state)
    }

    deinit { listener?.cancel() }
}
