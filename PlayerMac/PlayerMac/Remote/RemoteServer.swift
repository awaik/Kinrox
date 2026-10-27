import Foundation
import Observation
import RemoteProtocol
import RemoteTransport
import os

/// Connects secure transport with window, library, and Keychain.
@MainActor @Observable
final class RemoteServer {
    static let enabledKey = "remote.enabled"
    static let serverIdKey = "remote.serverId"
    let serverId: UUID
    let serverName: String
    private(set) var isEnabled: Bool
    private(set) var state = TransportServer.State.stopped
    private(set) var devices: [PairedDevice] = []
    private(set) var connectedDevices: [UUID: String] = [:]
    var errorMessage: String?
    @ObservationIgnored var onPairingRequested: (() -> Void)?
    @ObservationIgnored var openRecent: ((UUID) -> ProtocolError.Code?)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: any PairedDeviceStore
    @ObservationIgnored let recents: RecentFilesStore
    @ObservationIgnored let pairing: PairingCenter
    @ObservationIgnored private(set) var model: PlayerViewModel?
    @ObservationIgnored private var modelObserver: UUID?
    @ObservationIgnored private var recentObserver: UUID?
    @ObservationIgnored private var transport: TransportServer?
    @ObservationIgnored private var connections: [UUID: Message.Hello] = [:]
    @ObservationIgnored private var outboxes: [UUID: RemoteOutbox] = [:]
    @ObservationIgnored private var pairingConnection: UUID?
    @ObservationIgnored private var lifecycle: RemoteServerLifecycle?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var lastRecents: [RemoteProtocol.RecentItem] = []
    @ObservationIgnored private var recentTask: Task<Void, Never>?
    @ObservationIgnored private var seekPositionPending = false
    @ObservationIgnored private let logger = Logger(
        subsystem: "app.kinrox.player", category: "remote")
    @ObservationIgnored private lazy var publisher = RemoteStatePublisher { [weak self] state in
        self?.broadcast(.state(.init(), state))
    }

    init(
        defaults: UserDefaults = .standard,
        store: any PairedDeviceStore = KeychainPairedDeviceStore(),
        recents: RecentFilesStore, pairing: PairingCenter,
        serverName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.defaults = defaults
        self.store = store
        self.recents = recents
        self.pairing = pairing
        self.serverName = Self.bonjourName(serverName)
        isEnabled =
            defaults.object(forKey: Self.enabledKey) == nil
            || defaults.bool(forKey: Self.enabledKey)
        serverId =
            defaults.string(forKey: Self.serverIdKey).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(serverId.uuidString, forKey: Self.serverIdKey)
        lastRecents = recentSnapshot
        recentObserver = recents.observeChanges { [weak self] in self?.recentChanged() }
    }

    // Bonjour bounds name by UTF-8 bytes, not Character count.
    private static func bonjourName(_ value: String) -> String {
        var name = ""
        for character in value where character != "\0" {
            guard name.utf8.count + String(character).utf8.count <= 63 else { break }
            name.append(character)
        }
        return name.isEmpty ? "Mac" : name
    }

    func start(monitorSystem: Bool = true) {
        guard !running else { return }
        running = true
        reloadDevices()
        if monitorSystem {
            lifecycle = RemoteServerLifecycle(
                networkChanged: { [weak self] in self?.networkChanged() },
                sleep: { [weak self] in self?.willSleep() },
                wake: { [weak self] in self?.didWake() })
        }
        startListening()
    }

    func setEnabled(_ value: Bool) {
        guard value != isEnabled else { return }
        isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { startListening() } else { stopListening() }
    }

    func retry() {
        stopListening()
        startListening()
    }

    private func startListening() {
        guard running, isEnabled, !sleeping, transport == nil else { return }
        do {
            let advertisement = try BonjourAdvertiser(
                serverId: serverId, name: serverName,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "1.0")
            let transport = TransportServer(
                advertisement: advertisement,
                loadToken: { [store] in try store.token(for: $0) },
                saveToken: { [weak self, store] record in
                    do {
                        try store.save(record)
                        self?.reloadDevices()
                    } catch {
                        self?.errorMessage =
                            L10n.format("Failed to save remote. %@", error.localizedDescription)
                        throw error
                    }
                })
            self.transport = transport
            transport.onStateChange = { [weak self, weak transport] state in
                guard let self, self.transport === transport else { return }
                self.state = state
                if case .failed = state {
                    self.recentTask?.cancel()
                    self.recentTask = nil
                    self.publisher.reset()
                    self.transport = nil
                    self.logger.error("Remote server stopped due to network error")
                }
            }
            transport.onEvent = { [weak self] event in self?.receive(event) }
            try transport.start()
        } catch {
            transport = nil
            state = .failed(.invalidService)
            logger.error("Failed to start remote server")
        }
    }

    private func stopListening() {
        recentTask?.cancel()
        recentTask = nil
        let previous = transport
        transport = nil
        previous?.onStateChange = nil
        previous?.stop()
        for outbox in outboxes.values { outbox.close() }
        outboxes.removeAll()
        connections.removeAll()
        connectedDevices.removeAll()
        dismissPairing()
        publisher.reset()
        state = .stopped
    }

    func stop() {
        running = false
        lifecycle?.stop()
        lifecycle = nil
        stopListening()
    }

    func networkChanged() {
        guard running, isEnabled, !sleeping else { return }
        // NWListener follows interface changes itself. A path notification does
        // not mean that the listener or its authenticated connections failed.
        // Only recreate a missing/failed listener; peers handle actual path loss.
        startListening()
    }

    func willSleep() {
        sleeping = true
        stopListening()
    }
    func didWake() {
        sleeping = false
        startListening()
    }

    func connect(to model: PlayerViewModel?) {
        if let modelObserver { self.model?.removePlaybackObserver(modelObserver) }
        self.model = model
        seekPositionPending = false
        modelObserver = model?.observePlayback { [weak self] event in
            guard let self else { return }
            var immediate = false
            if case .seeking = event {
                self.seekPositionPending = true
                self.publisher.cancelPending()
                return
            }
            if self.model?.canControl != true || self.model?.isLoading == true {
                self.seekPositionPending = false
            }
            if case .playbackRestarted = event {
                // SEEK halted old ticks. time-pos may arrive after RESTART.
                guard !self.seekPositionPending else { return }
                immediate = true
            }
            if case .property(.position, .number(let position)) = event,
                position.isFinite, self.seekPositionPending
            {
                immediate = true
                self.seekPositionPending = false
            }
            self.publisher.update(self.snapshot, immediate: immediate)
        }
        publisher.update(snapshot, immediate: true)
    }

    func windowClosed() { declinePairing() }

    func declinePairing() {
        guard let id = pairingConnection, let transport else { return }
        transport.rejectPairing(connectionId: id)
        dismissPairing()
    }

    private func dismissPairing() {
        pairingConnection = nil
        pairing.dismiss()
    }

    func forget(_ id: UUID) {
        do {
            try store.forget(id)
            transport?.disconnect(deviceId: id)
            reloadDevices()
        } catch {
            errorMessage = L10n.format("Failed to forget remote. %@", error.localizedDescription)
        }
    }

    private func reloadDevices() {
        do { devices = try store.devices() } catch {
            errorMessage = L10n.format(
                "Failed to read paired remotes. %@", error.localizedDescription)
        }
    }

    private func receive(_ event: TransportServer.Event) {
        switch event {
        case .pairingRequested(let id, let device, let pin):
            pairingConnection = id
            onPairingRequested?()
            pairing.show(
                PairingPrompt(
                    deviceName: device.deviceName, code: pin,
                    expiresAt: Date().addingTimeInterval(PairingPrompt.lifetime)))
            pairing.onDecline = { [weak self] in self?.declinePairing() }
        case .authenticated(let id, let device):
            if pairingConnection == id { dismissPairing() }
            guard let transport else { return }
            recents.refreshAvailability()
            recentTask?.cancel()
            recentTask = nil
            // Existing remotes receive update, new remote receives initial snapshot.
            publishRecents()
            connections[id] = device
            connectedDevices[device.deviceId] = device.deviceName
            outboxes[id] = RemoteOutbox(
                send: { try await transport.send($0, to: id) },
                failed: { transport.disconnect(connectionId: id) })
            outboxes[id]?.enqueue(.state(.init(), snapshot))
            outboxes[id]?.enqueue(.recent(.init(), lastRecents))
        case .message(let id, let message):
            guard connections[id] != nil else { return }
            switch message {
            case .command(let header, let command):
                let response: Message
                if let code = execute(command) {
                    response = .error(
                        .init(),
                        .init(
                            replyTo: header.id, code: code,
                            message: Self.message(for: code)))
                } else {
                    response = .ack(.init(), .init(replyTo: header.id))
                }
                outboxes[id]?.enqueue(response)
            case .requestState:
                outboxes[id]?.enqueue(.state(.init(), snapshot))
            default: break
            }
        case .disconnected(let id, _):
            if pairingConnection == id { dismissPairing() }
            outboxes.removeValue(forKey: id)?.close()
            connections[id] = nil
            connectedDevices = connections.values.reduce(into: [:]) {
                $0[$1.deviceId] = $1.deviceName
            }
        }
    }

    var snapshot: PlayerState {
        let hasMedia = model?.canControl ?? false
        return PlayerState(
            title: hasMedia ? model?.displayTitle ?? "" : "",
            position: hasMedia ? model?.playbackPosition ?? 0 : 0,
            duration: hasMedia ? model?.duration ?? 0 : 0,
            paused: !hasMedia || model?.paused == true || model?.isAtEnd == true,
            volume: model?.playbackVolume ?? 100, fullscreen: model?.isFullscreen ?? false,
            hasMedia: hasMedia, canNext: hasMedia && model?.canNext == true,
            canPrevious: hasMedia && model?.canPrevious == true)
    }

    private var recentSnapshot: [RemoteProtocol.RecentItem] {
        recents.items.map {
            .init(
                id: $0.id, title: $0.title, duration: $0.duration,
                available: !recents.unavailable.contains($0.id))
        }
    }

    private func recentChanged() {
        // Single library op updates items, bookmark, and available individually.
        // Publish final state after synchronous completion, not intermediate snapshots.
        guard recentTask == nil else { return }
        recentTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.recentTask = nil
            self.publishRecents()
        }
    }

    private func publishRecents() {
        let current = recentSnapshot
        guard current != lastRecents else { return }
        lastRecents = current
        broadcast(.recent(.init(), current))
    }

    private func broadcast(_ message: Message) {
        for outbox in Array(outboxes.values) { outbox.enqueue(message) }
    }
}
