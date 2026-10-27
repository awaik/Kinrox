import Foundation
import Network
import RemoteProtocol

@MainActor final class ServerSession {
    let id = UUID()
    let peer: WebSocketPeer
    var onPairing: ((UUID, Message.Hello, String) -> Void)?
    var onAuthenticated: ((UUID, Message.Hello) -> Void)?
    var onMessage: ((UUID, Message) -> Void)?
    var onClosed: ((UUID, TransportFailure) -> Void)?
    private let handshake: ServerHandshake
    private var identity: Message.Hello?
    var deviceId: UUID? { identity?.deviceId }
    private var channel: SecureChannel?
    private var closing = false
    private var closed = false

    init(
        connection: NWConnection, advertisement: BonjourAdvertiser, gate: PairingGate,
        loadToken: @escaping (UUID) throws -> Data?,
        saveToken: @escaping (ServerHandshake.PairingRecord) throws -> Void
    ) {
        handshake = ServerHandshake(
            serverId: advertisement.serverId, serverName: advertisement.name,
            pairingGate: gate, loadToken: loadToken, saveToken: saveToken)
        peer = WebSocketPeer(connection: connection, role: .server)
        peer.onReady = { [weak self] in
            self?.peer.expectHandshakeProgress(within: TransportConfiguration.handshakeTimeout)
        }
        peer.onData = { [weak self] data in await self?.receive(data) }
        peer.onTick = { [weak self] in
            guard let self, !self.closing, self.channel == nil else { return }
            do { try self.handshake.checkDeadline() } catch let failure as SessionFailure {
                await self.handle(failure)?.value
            } catch { self.close(.invalidMessage) }
        }
        peer.onClose = { [weak self] failure in self?.close(failure) }
    }

    private func receive(_ data: Data) async {
        guard !closing else { return }
        do {
            if let channel {
                let message = try channel.open(data)
                switch message {
                case .bye: close(.closed)
                case .command, .requestState: onMessage?(id, message)
                default: close(.invalidMessage)
                }
                return
            }
            switch try handshake.receive(data) {
            case .send(let frame):
                identity = handshake.peerIdentity
                peer.expectHandshakeProgress(within: TransportConfiguration.handshakeTimeout)
                try await peer.send(frame)
            case .pairingChallenge(let pin, let frame):
                guard let identity else { throw TransportFailure.invalidMessage }
                peer.expectHandshakeProgress(within: nil)
                try await peer.send(frame)
                if !closing { onPairing?(id, identity, pin) }
            case .sendFinish(let frame):
                peer.expectHandshakeProgress(within: TransportConfiguration.handshakeTimeout)
                try await peer.send(frame)
                guard !closing, let identity else { return }
                channel = try handshake.finishSent()
                peer.expectHandshakeProgress(within: nil)
                onAuthenticated?(id, identity)
            }
        } catch let failure as SessionFailure { await handle(failure)?.value } catch {
            close(TransportFailure.wrapping(error))
        }
    }

    func send(_ message: Message) async throws {
        guard !closing, let channel else { throw TransportFailure.notConnected }
        do { try await peer.send(channel.seal(message)) } catch {
            let failure = TransportFailure.wrapping(error)
            close(failure)
            throw failure
        }
    }

    func rejectPairing() {
        guard !closing, let failure = handshake.rejectPairing() else { return }
        handle(failure)
    }

    @discardableResult
    private func handle(_ failure: SessionFailure) -> Task<Void, Never>? {
        guard !closing else { return nil }
        if failure.shouldCloseConnection {
            closing = true
            peer.expectHandshakeProgress(within: TransportConfiguration.handshakeTimeout)
        }
        // Rejection and PIN release are completed; network does not delay owner decision.
        return Task { await sendFailure(failure) }
    }

    private func sendFailure(_ failure: SessionFailure) async {
        guard !closed else { return }
        if failure.canSendResponse {
            do {
                let message = Message.error(.init(), failure.error)
                // Channel presence, even if already closed, never enables plaintext fallback.
                let frame = try channel.map { try $0.seal(message) } ?? Codec.encode(message)
                try await peer.send(frame)
            } catch {
                close(TransportFailure.wrapping(error))
                return
            }
        }
        if failure.shouldCloseConnection { close(.protocolFailure(failure.error)) }
    }

    func close(_ failure: TransportFailure = .closed) {
        guard !closed else { return }
        closing = true
        closed = true
        handshake.close()
        channel?.close()
        channel = nil
        peer.close(failure)
        onClosed?(id, failure)
        onPairing = nil
        onAuthenticated = nil
        onMessage = nil
        onClosed = nil
    }
}

extension TransportFailure {
    static func wrapping(_ error: any Error) -> TransportFailure {
        if let error = error as? TransportFailure { return error }
        if error is CancellationError { return .closed }
        if let error = error as? NWError { return .network(error) }
        if let error = error as? SessionFailure { return .protocolFailure(error.error) }
        if let error = error as? Codec.Failure { return .protocolFailure(error.error) }
        if let error = error as? ProtocolError { return .protocolFailure(error) }
        return .invalidMessage
    }
}
