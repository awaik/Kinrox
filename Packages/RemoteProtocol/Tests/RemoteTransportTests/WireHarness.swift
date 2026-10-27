import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport

/// Raw side is needed for deliberately invalid/control frames that remote API does not produce.
@MainActor final class WireEndpoint {
    let connection: NWConnection
    var ready = false
    var frames: [Data] = []
    var opcodes: [NWProtocolWebSocket.Opcode] = []
    var failure: NWError?
    var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.receive()
                case .failed(let error), .waiting(let error):
                    self.failure = error
                    self.closed = true
                case .cancelled: self.closed = true
                default: break
                }
            }
        }
    }

    func start() { connection.start(queue: .main) }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let error {
                    self.failure = error
                    self.closed = true
                    return
                }
                guard
                    let metadata = context?.protocolMetadata(
                        definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                else {
                    self.closed = true
                    return
                }
                self.opcodes.append(metadata.opcode)
                if metadata.opcode == .binary { self.frames.append(data ?? Data()) }
                self.receive()
            }
        }
    }

    func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode = .binary) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(
            identifier: UUID().uuidString, metadata: [metadata])
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed {
                    if let error = $0 {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    func close() {
        closed = true
        connection.cancel()
    }
    deinit { connection.cancel() }
}

@MainActor final class WireHarness {
    let listener: NWListener
    var peer: WebSocketPeer?
    var wire: WireEndpoint?
    var received: [Data] = []
    var peerFailure: TransportFailure?
    var port: NWEndpoint.Port?
    private var listenerFailure: NWError?
    private let permitsEndpoint: (NWEndpoint?) -> Bool

    init(
        role: WebSocketPeer.Role = .server, replies: Bool = true,
        permitsEndpoint: @escaping (NWEndpoint?) -> Bool = { LocalNetworkPolicy.permits($0) }
    ) throws {
        self.permitsEndpoint = permitsEndpoint
        let parameters = Self.parameters(listener: true, replies: role == .server || replies)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.port = self.listener.port
                case .failed(let error), .waiting(let error): self.listenerFailure = error
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else {
                    connection.cancel()
                    return
                }
                if role == .server {
                    self.attachPeer(connection, role: role)
                } else {
                    self.wire = WireEndpoint(connection)
                    self.wire?.start()
                }
            }
        }
    }

    static func parameters(listener: Bool = false, replies: Bool = true) -> NWParameters {
        let parameters = TransportConfiguration.parameters(listener: listener)
        // Setter updates underlying options; getter copy reflects Swift default value.
        (parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolWebSocket.Options)?
            .autoReplyPing = replies
        return parameters
    }

    func start(role: WebSocketPeer.Role = .server, replies: Bool = true) async throws {
        listener.start(queue: .main)
        try await eventually {
            if let failure = self.listenerFailure { throw failure }
            return self.port != nil
        }
        let connection = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: try #require(port)),
            using: Self.parameters(replies: role == .client || replies))
        if role == .client {
            attachPeer(connection, role: role)
        } else {
            wire = WireEndpoint(connection)
            wire?.start()
        }
        try await eventually {
            if let failure = self.peerFailure { throw failure }
            if let failure = self.wire?.failure { throw failure }
            return self.peer?.isReady == true && self.wire?.ready == true
        }
    }

    private func attachPeer(_ connection: NWConnection, role: WebSocketPeer.Role) {
        let peer = WebSocketPeer(
            connection: connection, role: role, interval: .milliseconds(100),
            timeout: .milliseconds(750), permitsEndpoint: permitsEndpoint)
        self.peer = peer
        peer.onData = { [weak self] in self?.received.append($0) }
        peer.onClose = { [weak self] in self?.peerFailure = $0 }
        peer.start()
    }

    func stop() {
        wire?.close()
        peer?.close()
        listener.cancel()
    }
}
