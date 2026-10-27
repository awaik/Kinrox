import Foundation
import RemoteProtocol
import RemoteTransport
import Testing

@testable import Kinrox

enum RemoteTestError: Error { case timeout, storage }

@MainActor
func waitForRemote(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while try !condition() {
        guard ContinuousClock.now < deadline else { throw RemoteTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
final class MemoryPairedDevices: PairedDeviceStore {
    var records: [UUID: ServerHandshake.PairingRecord] = [:]
    var fails = false
    var onRead: (() -> Void)?
    func devices() throws -> [PairedDevice] {
        onRead?()
        return records.values.map {
            PairedDevice(id: $0.deviceId, name: $0.deviceName, pairedAt: Date())
        }
    }
    func token(for id: UUID) throws -> Data? { records[id]?.token }
    func save(_ record: ServerHandshake.PairingRecord) throws {
        if fails { throw RemoteTestError.storage }
        records[record.deviceId] = record
    }
    func forget(_ id: UUID) throws {
        if fails { throw RemoteTestError.storage }
        records[id] = nil
    }
}

@MainActor
final class RemoteServerHarness {
    let defaults: UserDefaults
    let store: any PairedDeviceStore
    let recents: RecentFilesStore
    let pairing = PairingCenter()
    let server: RemoteServer
    let engine = FakePlayerEngine()
    let model: PlayerViewModel
    let browser = BonjourBrowser()
    var clients: [TransportClient] = []
    var messages: [Message] = []
    var tokens: [UUID: Data] = [:]
    let folder: URL

    init(store: any PairedDeviceStore = MemoryPairedDevices(), preloadRecent: Bool = false) throws {
        let id = UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: "app.kinrox.tests.remote.\(id)"))
        self.store = store
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "kinrox-remote-\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recents = RecentFilesStore(fileURL: folder.appendingPathComponent("recent.json"))
        if preloadRecent { recents.noteOpened(folder.appendingPathComponent("1.mkv")) }
        server = RemoteServer(
            defaults: defaults, store: store, recents: recents, pairing: pairing,
            serverName: "Kinrox-Test-\(id.prefix(8))")
        let items = [
            folder.appendingPathComponent("1.mkv"), folder.appendingPathComponent("2.mkv"),
        ]
        model = PlayerViewModel(engine: engine, recents: recents) {
            FolderPlaylist(items: items, current: $0)
        }
        server.connect(to: model)
    }

    func start() async throws {
        server.start(monitorSystem: false)
        browser.start()
        try await waitForRemote { self.server.isOnline && self.discovered != nil }
    }

    var discovered: DiscoveredServer? {
        browser.servers.first { $0.id == server.serverId && $0.isAvailable }
    }

    func client(_ id: UUID = UUID(), token: Data? = nil) throws -> TransportClient {
        let client = try TransportClient(
            server: #require(discovered), deviceId: id,
            deviceName: "iPhone M4.4", appVersion: "1.0",
            mode: token.map { .authenticate(token: $0, serverId: server.serverId) } ?? .pair,
            saveToken: { [weak self] in self?.tokens[id] = $0 })
        client.onEvent = { [weak self] event in
            if case .message(let message) = event { self?.messages.append(message) }
        }
        clients.append(client)
        client.start()
        return client
    }

    func pair(_ id: UUID = UUID()) async throws -> TransportClient {
        let client = try client(id)
        try await waitForRemote { client.state == .awaitingPIN && self.pairing.prompt != nil }
        try await client.submitPIN(#require(pairing.prompt?.code))
        try await waitForRemote {
            if case .closed(let failure) = client.state {
                if let error = self.server.errorMessage { Issue.record(Comment(rawValue: error)) }
                throw failure
            }
            return client.state == .connected && self.messages.count >= 2
        }
        return client
    }

    func command(_ command: Command, client: TransportClient) async throws -> Message {
        try #require(client.state == .connected, "Before \(command.kind): \(client.state)")
        let header = Message.Header()
        try await client.send(.command(header, command))
        try await waitForRemote { self.reply(to: header.id) != nil }
        return try #require(reply(to: header.id))
    }

    private func reply(to id: UUID) -> Message? {
        messages.first {
            switch $0 {
            case .ack(_, let body): body.replyTo == id
            case .error(_, let body): body.replyTo == id
            default: false
            }
        }
    }

    func loaded() async throws {
        let url = folder.appendingPathComponent("1.mkv")
        try Data().write(to: url)
        model.open(url: url)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(120)))
        try await waitForRemote { self.model.canNext }
    }

    func stop() async {
        for client in clients { client.close() }
        browser.stop()
        server.stop()
        server.connect(to: nil)
        await model.shutdown()
    }
}
