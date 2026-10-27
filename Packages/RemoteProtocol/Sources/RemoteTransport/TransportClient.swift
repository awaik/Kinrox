import Foundation
import Network
import RemoteProtocol

/// One instance per connection attempt. Retry creates fresh keys and queue.
@MainActor public final class TransportClient {
    public enum State: Equatable {
        case idle, connecting, handshaking, awaitingPIN, connected
        case closed(TransportFailure)
    }
    public enum Event {
        case enterPIN, retryPIN, connected
        case message(Message)
        case protocolError(ProtocolError)
    }
    public private(set) var state = State.idle
    public var onStateChange: ((State) -> Void)?
    public var onEvent: ((Event) -> Void)?
    private let peer: WebSocketPeer
    private let handshake: ClientHandshake
    private let saveToken: (Data) throws -> Void
    private var channel: SecureChannel?
    private var closing = false

    public convenience init(
        server: DiscoveredServer, deviceId: UUID, deviceName: String,
        appVersion: String, mode: ClientHandshake.Mode, saveToken: @escaping (Data) throws -> Void
    ) throws {
        guard server.isAvailable else { throw TransportFailure.notConnected }
        self.init(
            endpoint: server.endpoint, serverId: server.id, deviceId: deviceId,
            deviceName: deviceName, appVersion: appVersion, mode: mode, saveToken: saveToken)
    }

    init(
        endpoint: NWEndpoint, serverId: UUID, deviceId: UUID, deviceName: String,
        appVersion: String, mode: ClientHandshake.Mode, saveToken: @escaping (Data) throws -> Void
    ) {
        handshake = ClientHandshake(
            deviceId: deviceId, deviceName: deviceName, appVersion: appVersion,
            mode: mode, expectedServerId: serverId)
        self.saveToken = saveToken
        peer = WebSocketPeer(
            connection: NWConnection(to: endpoint, using: TransportConfiguration.parameters()),
            role: .client)
        peer.onReady = { [weak self] in
            guard let self, !self.closing else { return }
            self.peer.expectHandshakeProgress(within: TransportConfiguration.handshakeTimeout)
            self.setState(.handshaking)
            do { try await self.peer.send(self.handshake.start()) } catch {
                self.close(TransportFailure.wrapping(error))
            }
        }
        peer.onData = { [weak self] data in await self?.receive(data) }
        peer.onClose = { [weak self] failure in self?.close(failure) }
    }

    public func start() {
        guard state == .idle else { return }
        setState(.connecting)
        peer.start()
    }

    public func submitPIN(_ pin: String) async throws {
        guard state == .awaitingPIN, !closing else { throw TransportFailure.notConnected }
        do {
            let frame = try handshake.submitPIN(pin)
            peer.expectHandshakeProgress(within: TransportConfiguration.handshakeTimeout)
            setState(.handshaking)
            try await peer.send(frame)
        } catch {
            let failure = TransportFailure.wrapping(error)
            close(failure)
            throw failure
        }
    }

    public func send(_ message: Message) async throws {
        guard state == .connected, !closing, let channel else {
            throw TransportFailure.notConnected
        }
        do { try await peer.send(channel.seal(message)) } catch {
            let failure = TransportFailure.wrapping(error)
            close(failure)
            throw failure
        }
    }

    private func receive(_ data: Data) async {
        guard !closing else { return }
        do {
            if let channel {
                let message = try channel.open(data)
                switch message {
                case .bye: close()
                case .state, .recent, .ack, .error: onEvent?(.message(message))
                default: close(.invalidMessage)
                }
                return
            }
            switch try handshake.receive(data) {
            case .send(let frame):
                peer.expectHandshakeProgress(within: TransportConfiguration.handshakeTimeout)
                try await peer.send(frame)
            case .enterPIN:
                peer.expectHandshakeProgress(within: nil)
                setState(.awaitingPIN)
                onEvent?(.enterPIN)
            case .retryPIN(let error):
                peer.expectHandshakeProgress(within: nil)
                setState(.awaitingPIN)
                onEvent?(.protocolError(error))
                onEvent?(.retryPIN)
            case .authenticated(let token, let channel):
                if let token {
                    do { try saveToken(token) } catch {
                        channel.close()
                        throw TransportFailure.storageFailure
                    }
                }
                guard !closing else {
                    channel.close()
                    return
                }
                self.channel = channel
                peer.expectHandshakeProgress(within: nil)
                setState(.connected)
                onEvent?(.connected)
            }
        } catch let failure as SessionFailure {
            if failure.canSendResponse, let channel, !channel.isClosed {
                do { try await peer.send(channel.seal(.error(.init(), failure.error))) } catch {
                    close(TransportFailure.wrapping(error))
                    return
                }
            }
            if failure.shouldCloseConnection {
                close(.protocolFailure(failure.error))
            } else {
                onEvent?(.protocolError(failure.error))
            }
        } catch { close(TransportFailure.wrapping(error)) }
    }

    public func close(_ failure: TransportFailure = .closed) {
        guard !closing else { return }
        closing = true
        handshake.close()
        channel?.close()
        channel = nil
        peer.close(failure)
        setState(.closed(failure))
    }

    private func setState(_ state: State) {
        self.state = state
        onStateChange?(state)
    }
}
