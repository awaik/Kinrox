import Foundation
import Observation
import RemoteProtocol
import RemoteTransport
import UIKit
import os

/// Navigation and state strictly on MainActor; one epoch per network attempt.
@MainActor @Observable
final class RemoteAppModel {
    enum Screen: Hashable { case players, pairing, remote }
    enum ConnectionState: Equatable {
        case idle, connecting, handshaking, awaitingPIN, checkingPIN, connected, reconnecting
        case failed, needsPairing, incompatible
    }
    let isDemo: Bool
    var screen = Screen.players
    var connectionState = ConnectionState.idle
    var players: [MacPlayer] = []
    var selected: SavedMac?
    var state = PlayerState.empty
    var recents: [RecentItem] = []
    var discoveryStatus = RemoteDiscoveryStatus.searching
    var pairingMessage: String?
    var pairingRevision = 0
    var failureMessage: String?
    var commandError: String?
    var retryAttempt = 0
    var nextRetryDelay: TimeInterval = 0
    var scrubTarget: Double?
    var hasState = false
    @ObservationIgnored let scheduler: any RemoteScheduler
    @ObservationIgnored var credentials: (any ServerCredentialStore)?
    @ObservationIgnored var preferences: RemotePreferences?
    @ObservationIgnored var discovery: (any RemoteDiscovery)?
    @ObservationIgnored let factory: RemoteConnectionFactory
    @ObservationIgnored var networkMonitor: RemoteNetworkMonitor?
    @ObservationIgnored var networkState = RemoteNetworkState.unknown
    @ObservationIgnored var savedServers: [SavedMac] = []
    @ObservationIgnored var client: (any RemoteConnection)?
    @ObservationIgnored var retiringClient: (any RemoteConnection)?
    @ObservationIgnored var backgroundLease: RemoteBackgroundLease?
    @ObservationIgnored var retirement: (any RemoteCancellation)?
    @ObservationIgnored var epoch = UUID()
    @ObservationIgnored var retryTimer: (any RemoteCancellation)?
    @ObservationIgnored var retryDeadline: (any RemoteCancellation)?
    @ObservationIgnored var hintTimer: (any RemoteCancellation)?
    @ObservationIgnored var searchElapsed = false
    @ObservationIgnored var foreground = false
    @ObservationIgnored var started = false
    @ObservationIgnored var pairingAttempt = false
    @ObservationIgnored var waitingForDiscovery = false
    @ObservationIgnored var receivedAt: TimeInterval = 0
    @ObservationIgnored var frozenPosition: Double = 0
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pending: [UUID: PendingCommand] = [:]
    @ObservationIgnored var volumeTimer: (any RemoteCancellation)?
    @ObservationIgnored var pendingVolume: Double?
    @ObservationIgnored var lastVolumeSent = -Double.infinity
    @ObservationIgnored var demo: RemoteDemoStore?
    @ObservationIgnored let monitorNetwork: Bool
    @ObservationIgnored let logger = Logger(subsystem: "app.kinrox.remote", category: "connection")

    init(
        isDemo: Bool = false, credentials: (any ServerCredentialStore)? = nil,
        preferences: RemotePreferences? = nil, discovery: (any RemoteDiscovery)? = nil,
        scheduler: any RemoteScheduler = LiveRemoteScheduler(), monitorNetwork: Bool = true,
        factory: @escaping RemoteConnectionFactory = { server, deviceId, mode, save in
            try TransportClient(
                server: server, deviceId: deviceId, deviceName: UIDevice.current.name,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "1.0",
                mode: mode, saveToken: save)
        }
    ) {
        self.isDemo = isDemo
        self.scheduler = scheduler
        self.factory = factory
        self.monitorNetwork = monitorNetwork
        if isDemo {
            demo = RemoteDemoStore()
            syncDemo()
        } else {
            self.credentials = credentials ?? KeychainServerStore()
            self.preferences = preferences ?? RemotePreferences()
            self.discovery = discovery ?? BonjourBrowser()
        }
    }

    var controlsEnabled: Bool { connectionState == .connected && hasState }
    var supportsScreensavers: Bool { hasState && state.screensaver != nil }
    var canNext: Bool { controlsEnabled && state.hasMedia && state.canNext }
    var canPrevious: Bool { controlsEnabled && state.hasMedia && state.canPrevious }
    var position: Double {
        guard controlsEnabled else { return frozenPosition }
        let elapsed =
            !state.paused && state.hasMedia && state.screensaver != .matrix
            ? max(0, scheduler.now - receivedAt) : 0
        return min(state.duration, max(0, state.position + elapsed))
    }

    func start() {
        guard !started else { return }
        started = true
        foreground = true
        guard !isDemo else { return }
        reloadSavedServers()
        if let selected = preferences?.selected {
            do {
                if try credentials?.token(for: selected.id) != nil {
                    self.selected = selected
                    screen = .remote
                } else {
                    preferences?.selected = nil
                }
            } catch { failStorage(error) }
        }
        startDiscovery()
        if selected != nil { restoreSelected() }
    }

    func startDiscovery() {
        guard !isDemo, foreground, let discovery else { return }
        searchElapsed = false
        hintTimer?.cancel()
        hintTimer = scheduler.schedule(after: 10) { [weak self] in
            self?.searchElapsed = true
            self?.refreshDiscovery()
        }
        discovery.onChange = { [weak self] in self?.refreshDiscovery() }
        if monitorNetwork, networkMonitor == nil {
            networkMonitor = RemoteNetworkMonitor { [weak self] state in
                self?.networkChanged(state)
            }
        }
        discovery.start()
        refreshDiscovery()
    }

    func retryDiscovery() {
        discovery?.stop()
        startDiscovery()
    }

    func networkChanged(_ state: RemoteNetworkState) {
        guard foreground else { return }
        networkState = state
        if state == .available { restartDiscoveryIfNeeded() }
        refreshDiscovery()
        if state == .unavailable, connectionState == .connected {
            connectionLost(.notConnected)
        }
    }

    func restartDiscoveryIfNeeded() {
        guard foreground, let discovery else { return }
        switch discovery.state {
        case .failed, .stopped: discovery.start()
        default: break
        }
    }

    func reloadSavedServers() {
        do { savedServers = try credentials?.servers() ?? [] } catch {
            failureMessage = L10n.format("Failed to read pairings. %@", error.localizedDescription)
        }
    }

    func refreshDiscovery() {
        guard !isDemo, let discovery else { return }
        players = Self.merge(
            discovered: discovery.servers, saved: savedServers,
            selected: preferences?.selected, rejected: preferences?.rejectedServers ?? [])
        if let id = selected?.id, let current = players.first(where: { $0.id == id }) {
            selected?.name = current.name
            if preferences?.selected?.id == id { preferences?.selected = selected }
        }
        discoveryStatus = .resolve(
            browser: discovery.state, network: networkState,
            hasServers: discovery.servers.contains(where: \.isAvailable), elapsed: searchElapsed)
        if foreground, waitingForDiscovery, client == nil,
            discovery.servers.contains(where: { $0.id == selected?.id && $0.isAvailable })
        {
            attemptConnection(pair: pairingAttempt)
        }
    }

    static func merge(
        discovered: [DiscoveredServer], saved: [SavedMac], selected: SavedMac?,
        rejected: Set<UUID>
    ) -> [MacPlayer] {
        var result: [UUID: MacPlayer] = [:]
        for item in saved + (selected.map { [$0] } ?? []) {
            result[item.id] = MacPlayer(
                id: item.id, name: item.name, status: .unavailable, detail: L10n.text("Unavailable")
            )
        }
        let paired = Set(saved.map(\.id)).subtracting(rejected)
        for item in discovered {
            let status: MacPlayer.Status =
                !item.isAvailable ? .unavailable : paired.contains(item.id) ? .paired : .new
            result[item.id] = MacPlayer(
                id: item.id, name: item.name, status: status,
                detail: status == .unavailable
                    ? L10n.text("Unavailable")
                    : status == .paired ? L10n.text("Paired") : L10n.text("New · code required"))
        }
        return result.values.sorted {
            if $0.name == $1.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func select(_ player: MacPlayer) {
        guard player.status != .unavailable else { return }
        cancelConnection()
        selected = SavedMac(id: player.id, name: player.name)
        state = .empty
        frozenPosition = 0
        recents = []
        hasState = false
        failureMessage = nil
        commandError = nil
        if isDemo {
            if player.status == .new {
                demo?.beginPairing()
                screen = .pairing
                connectionState = .awaitingPIN
            } else {
                screen = .remote
                connectionState = .connected
                syncDemo()
            }
            return
        }
        do {
            let token = try credentials?.token(for: player.id)
            if token != nil, preferences?.rejectedServers.contains(player.id) != true {
                preferences?.selected = selected
                screen = .remote
                attemptConnection(pair: false)
            } else {
                beginPairing()
            }
        } catch { failStorage(error) }
    }

    func beginPairing() {
        guard selected != nil, foreground else { return }
        cancelConnection()
        pairingMessage = nil
        failureMessage = nil
        pairingRevision += 1
        screen = .pairing
        if isDemo {
            demo?.beginPairing()
            connectionState = .awaitingPIN
            return
        }
        attemptConnection(pair: true)
    }

    func restoreSelected() {
        guard let selected else { return }
        do {
            guard try credentials?.token(for: selected.id) != nil,
                preferences?.rejectedServers.contains(selected.id) != true
            else {
                connectionState = .needsPairing
                failureMessage = L10n.text("Connect this Mac again using code.")
                return
            }
            attemptConnection(pair: false)
        } catch { failStorage(error) }
    }

    func returnToPlayers() {
        cancelConnection()
        preferences?.selected = nil
        selected = nil
        screen = .players
        connectionState = .idle
    }

    func forgetSelected() {
        guard let selected else { return }
        cancelConnection()
        do {
            if let demo, let player = demo.players.first(where: { $0.id == selected.id }) {
                demo.forget(player)
                syncDemo()
            } else {
                try credentials?.forget(selected.id)
            }
            preferences?.forget(selected.id)
            reloadSavedServers()
            self.selected = nil
            screen = .players
            connectionState = .idle
            refreshDiscovery()
        } catch { failStorage(error) }
    }

    func failStorage(_ error: any Error) {
        cancelConnection()
        connectionState = .failed
        failureMessage = L10n.format("Pairing not saved. %@", error.localizedDescription)
        logger.error("Local pairing storage error")
    }
}

extension PlayerState {
    static var empty: Self {
        .init(
            title: "", position: 0, duration: 0, paused: true, volume: 0,
            fullscreen: false, hasMedia: false, canNext: false, canPrevious: false)
    }
}
