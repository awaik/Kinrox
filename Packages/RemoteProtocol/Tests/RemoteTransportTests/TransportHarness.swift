import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport

@MainActor func eventually(timeout: Duration = .seconds(5), _ condition: () throws -> Bool)
    async throws
{
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try !condition() {
        if ContinuousClock.now >= deadline { throw TransportTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

enum TransportTestError: Error { case timeout, storage }

@MainActor final class TransportHarness {
    let id = UUID()
    let server: TransportServer
    var clients: [TransportClient] = []
    var pins: [UUID: String] = [:]
    var deviceConnections: [UUID: UUID] = [:]
    var authenticated: [UUID] = []
    var incoming: [Message] = []
    var outgoing: [Message] = []
    var clientTokens: [UUID: Data] = [:]
    var failures: [TransportFailure] = []
    var retries = 0
    var failClientSave = false
    var failServerSave = false
    private let storage: TestTokenStorage

    init() throws {
        let storage = TestTokenStorage()
        self.storage = storage
        server = TransportServer(
            advertisement: try BonjourAdvertiser(
                serverId: id,
                name: "Kinrox-Test-\(UUID().uuidString.prefix(8))", appVersion: "1.0"),
            loadToken: { storage.tokens[$0] },
            saveToken: {
                if storage.fail { throw TransportTestError.storage }
                storage.tokens[$0.deviceId] = $0.token
            })
        server.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .pairingRequested(let connection, let device, let pin):
                self.deviceConnections[device.deviceId] = connection
                self.pins[device.deviceId] = pin
            case .authenticated(let connection, let device):
                self.deviceConnections[device.deviceId] = connection
                self.authenticated.append(device.deviceId)
            case .message(_, let message): self.incoming.append(message)
            case .disconnected(_, let failure): self.failures.append(failure)
            }
        }
    }

    var endpoint: NWEndpoint {
        guard case .ready(let port) = server.state else {
            preconditionFailure("Server is not ready")
        }
        return .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    }

    func start(advertise: Bool = false) async throws {
        storage.fail = failServerSave
        try server.start(advertise: advertise, loopbackOnly: !advertise)
        try await eventually {
            if case .failed(let failure) = self.server.state { throw failure }
            if case .ready = self.server.state { return true }
            return false
        }
    }

    func client(deviceId: UUID, token: Data? = nil) -> TransportClient {
        let client = TransportClient(
            endpoint: endpoint, serverId: id, deviceId: deviceId,
            deviceName: "Test remote", appVersion: "1.0",
            mode: token.map { .authenticate(token: $0, serverId: id) } ?? .pair,
            saveToken: { [weak self] data in
                guard let self, !self.failClientSave else { throw TransportTestError.storage }
                self.clientTokens[deviceId] = data
            })
        client.onEvent = { [weak self] event in
            switch event {
            case .message(let message): self?.outgoing.append(message)
            case .retryPIN: self?.retries += 1
            default: break
            }
        }
        clients.append(client)
        client.start()
        return client
    }

    func pair(deviceId: UUID = UUID()) async throws -> TransportClient {
        let client = client(deviceId: deviceId)
        try await eventually {
            if case .closed(let failure) = client.state { throw failure }
            return client.state == .awaitingPIN && self.pins[deviceId] != nil
        }
        try await client.submitPIN(try #require(pins[deviceId]))
        try await eventually {
            if case .closed(let failure) = client.state { throw failure }
            return client.state == .connected && self.authenticated.contains(deviceId)
        }
        return client
    }

    func stop() {
        for client in clients { client.close() }
        server.stop()
    }
}

@MainActor private final class TestTokenStorage {
    var tokens: [UUID: Data] = [:]
    var fail = false
}
