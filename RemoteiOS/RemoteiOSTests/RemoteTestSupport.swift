import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport
@testable import RemoteiOS

@MainActor final class ManualRemoteScheduler: RemoteScheduler {
    final class Ticket: RemoteCancellation {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    struct Work {
        let due: Double
        let order: Int
        let ticket: Ticket
        let action: @MainActor () -> Void
    }
    var now = 0.0
    var work: [Work] = []
    var order = 0
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> any RemoteCancellation
    {
        let ticket = Ticket()
        order += 1
        work.append(Work(due: now + delay, order: order, ticket: ticket, action: action))
        return ticket
    }
    func advance(_ seconds: Double) {
        let end = now + seconds
        while let next = work.filter({ !$0.ticket.cancelled && $0.due <= end }).sorted(by: {
            $0.due == $1.due ? $0.order < $1.order : $0.due < $1.due
        }).first {
            work.removeAll { $0.order == next.order }
            now = next.due
            next.action()
        }
        now = end
    }
}

enum RemoteTestFailure: Error { case storage, timeout }

@MainActor final class MemoryServerStore: ServerCredentialStore {
    var records: [UUID: (SavedMac, Data)] = [:]
    var fails = false
    var calls = 0
    func servers() throws -> [SavedMac] {
        calls += 1
        return records.values.map { $0.0 }
    }
    func token(for id: UUID) throws -> Data? {
        calls += 1
        if fails { throw RemoteTestFailure.storage }
        return records[id]?.1
    }
    func save(token: Data, server: SavedMac) throws {
        calls += 1
        if fails { throw RemoteTestFailure.storage }
        records[server.id] = (server, token)
    }
    func forget(_ id: UUID) throws {
        calls += 1
        if fails { throw RemoteTestFailure.storage }
        records[id] = nil
    }
}

@MainActor final class FakeRemoteDiscovery: RemoteDiscovery {
    var servers: [DiscoveredServer] = []
    var state = BonjourBrowser.State.ready
    var onChange: (() -> Void)?
    var starts = 0
    var stops = 0
    func start() {
        starts += 1
        switch state {
        case .stopped, .failed: state = .searching
        default: break
        }
        onChange?()
    }
    func stop() {
        stops += 1
        state = .stopped
        for index in servers.indices { servers[index].isAvailable = false }
        onChange?()
    }
}

@MainActor final class FakeRemoteConnection: RemoteConnection {
    var onStateChange: ((TransportClient.State) -> Void)?
    var onEvent: ((TransportClient.Event) -> Void)?
    var starts = 0
    var closes = 0
    var pins: [String] = []
    var messages: [Message] = []
    var sendOperation: ((Message) async throws -> Void)?
    let mode: ClientHandshake.Mode
    let save: (Data) throws -> Void
    init(mode: ClientHandshake.Mode, save: @escaping (Data) throws -> Void) {
        self.mode = mode
        self.save = save
    }
    func start() {
        starts += 1
        onStateChange?(.connecting)
    }
    func submitPIN(_ pin: String) async throws { pins.append(pin) }
    func send(_ message: Message) async throws {
        messages.append(message)
        try await sendOperation?(message)
    }
    func close(_ failure: TransportFailure) {
        closes += 1
        onStateChange?(.closed(failure))
    }
    func connected(pairing: Bool = false) {
        if pairing {
            do { try save(Data(repeating: 42, count: 32)) } catch {
                onStateChange?(.closed(.storageFailure))
                return
            }
        }
        onEvent?(.connected)
    }
    func emit(_ state: PlayerState) { onEvent?(.message(.state(.init(), state))) }
    var commands: [Command] {
        messages.compactMap { if case .command(_, let value) = $0 { value } else { nil } }
    }
}

@MainActor final class RemoteModelHarness {
    let clock = ManualRemoteScheduler()
    let store = MemoryServerStore()
    let discovery = FakeRemoteDiscovery()
    let defaults: UserDefaults
    let preferences: RemotePreferences
    var connections: [FakeRemoteConnection] = []
    var model: RemoteAppModel!
    let serverId = UUID()
    init(
        paired: Bool = true, demo: Bool = false, restore: Bool = false,
        discoverImmediately: Bool = true
    ) {
        defaults = UserDefaults(suiteName: "Kinrox.M5.Tests.\(UUID())")!
        preferences = RemotePreferences(defaults: defaults)
        discovery.servers = discoverImmediately ? [Self.server(id: serverId)] : []
        if !discoverImmediately { discovery.state = .stopped }
        if paired {
            store.records[serverId] = (
                SavedMac(id: serverId, name: "Mac"), Data(repeating: 42, count: 32)
            )
        }
        if restore { preferences.selected = SavedMac(id: serverId, name: "Mac") }
        model = RemoteAppModel(
            isDemo: demo, credentials: store, preferences: preferences,
            discovery: discovery, scheduler: clock, monitorNetwork: false
        ) { [weak self] _, _, mode, save in
            let client = FakeRemoteConnection(mode: mode, save: save)
            self?.connections.append(client)
            return client
        }
        model.start()
    }
    static func server(id: UUID, name: String = "Mac", version: Int = 1) -> DiscoveredServer {
        DiscoveredServer(
            endpoint: .service(name: name, type: "_kinrox._tcp", domain: "local.", interface: nil),
            record: NWTXTRecord(["id": id.uuidString, "v": "\(version)", "pv": "1.0"]))!
    }
    var current: FakeRemoteConnection { connections.last! }
    func connect() {
        model.select(model.players.first { $0.id == serverId }!)
        current.connected()
        current.emit(Self.playing)
    }
    static var playing: PlayerState {
        .init(
            title: "Video.mkv", position: 10, duration: 100, paused: false, volume: 0,
            fullscreen: false, hasMedia: true, canNext: false, canPrevious: true)
    }
}

@MainActor func settleTasks() async { for _ in 0..<20 { await Task.yield() } }

@MainActor func waitForRemote(timeout: Duration = .seconds(10), _ condition: () throws -> Bool)
    async throws
{
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try !condition() {
        if ContinuousClock.now >= deadline { throw RemoteTestFailure.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}
