import Foundation
import RemoteProtocol
import RemoteTransport

extension RemoteAppModel {
    func attemptConnection(pair: Bool) {
        guard foreground, let selected, client == nil else { return }
        retirement?.cancel()
        retirement = nil
        retiringClient?.close(.closed)
        retiringClient = nil
        backgroundLease?.end()
        backgroundLease = nil
        retryTimer?.cancel()
        retryTimer = nil
        pairingAttempt = pair
        waitingForDiscovery = false
        if retryAttempt == 0 { connectionState = .connecting }
        restartDiscoveryIfNeeded()
        guard
            let server = discovery?.servers.first(where: { $0.id == selected.id && $0.isAvailable })
        else {
            waitingForDiscovery = true
            if connectionState == .reconnecting {
                scheduleRetry()
            } else {
                if !pair { startRetryDeadline() }
                // Absence of initial Bonjour results does not imply connection failure.
                retryTimer = scheduler.schedule(after: 10) { [weak self] in
                    guard let self, self.foreground, self.waitingForDiscovery else { return }
                    self.retryTimer = nil
                    if pair {
                        self.connectionLost(.notConnected)
                    } else {
                        self.scheduleRetry()
                    }
                }
            }
            return
        }
        do {
            let mode: ClientHandshake.Mode
            if pair {
                mode = .pair
            } else {
                guard let token = try credentials?.token(for: selected.id) else {
                    connectionState = .needsPairing
                    failureMessage = L10n.text("Connect this Mac using code.")
                    return
                }
                mode = .authenticate(token: token, serverId: selected.id)
            }
            let attempt = UUID()
            epoch = attempt
            let connection = try factory(server, preferences!.deviceId, mode) { [weak self] token in
                guard let self, self.epoch == attempt, self.foreground,
                    let credentials = self.credentials
                else { throw TransportFailure.closed }
                try credentials.save(token: token, server: self.selected ?? selected)
                self.preferences?.selected = self.selected ?? selected
                self.preferences?.rejectedServers.remove(selected.id)
                self.reloadSavedServers()
                self.refreshDiscovery()
            }
            client = connection
            connection.onStateChange = { [weak self] state in
                guard let self, self.epoch == attempt, self.foreground else { return }
                self.connectionChanged(state)
            }
            connection.onEvent = { [weak self] event in
                guard let self, self.epoch == attempt, self.foreground else { return }
                self.receive(event)
            }
            if connectionState != .reconnecting { connectionState = .connecting }
            connection.start()
        } catch let failure as TransportFailure { connectionLost(failure) } catch {
            failStorage(error)
        }
    }

    func connectionChanged(_ state: TransportClient.State) {
        switch state {
        case .idle: break
        case .connecting:
            if connectionState != .reconnecting { connectionState = .connecting }
        case .handshaking:
            if connectionState != .reconnecting && connectionState != .checkingPIN {
                connectionState = .handshaking
            }
        case .awaitingPIN: connectionState = .awaitingPIN
        case .connected: break  // Open control after authenticated event and initial state.
        case .closed(let failure): connectionLost(failure)
        }
    }

    func receive(_ event: TransportClient.Event) {
        switch event {
        case .enterPIN: connectionState = .awaitingPIN
        case .retryPIN:
            connectionState = .awaitingPIN
            pairingRevision += 1
        case .protocolError(let error):
            if screen == .pairing {
                pairingMessage =
                    error.code == .authFailed
                    ? L10n.text("Incorrect code. Try again.") : Self.message(for: error)
            } else {
                commandError = Self.message(for: error)
            }
        case .connected:
            retryTimer?.cancel()
            retryTimer = nil
            retryDeadline?.cancel()
            retryDeadline = nil
            retryAttempt = 0
            connectionState = .connected
            screen = .remote
            failureMessage = nil
            pairingMessage = nil
            pairingAttempt = false
            hasState = false
            logger.info("Secure connection established")
        case .message(let message): receiveMessage(message)
        }
    }

    func submitPIN(_ code: String) {
        guard connectionState == .awaitingPIN, code.utf8.count == 6,
            code.utf8.allSatisfy({ (48...57).contains($0) })
        else { return }
        connectionState = .checkingPIN
        pairingMessage = nil
        if isDemo {
            submitDemoPIN(code)
            return
        }
        guard let client else { return }
        let attempt = epoch
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard let self, self.epoch == attempt, !Task.isCancelled else { return }
            do { try await client.submitPIN(code) } catch {
                if self.epoch == attempt {
                    self.connectionLost(error as? TransportFailure ?? .closed)
                }
            }
            self.tasks[id] = nil
        }
    }

    func connectionLost(_ failure: TransportFailure) {
        let wasPairing = pairingAttempt
        // Series deadline preserved; specific socket operations canceled.
        detachClient()
        switch failure {
        case .storageFailure:
            cancelRetries()
            connectionState = .failed
            failureMessage = L10n.text("Failed to save pairing in Keychain. Request a new code.")
        case .protocolFailure(let error):
            cancelRetries()
            failureMessage = Self.message(for: error)
            if error.code == .incompatibleVersion {
                connectionState = .incompatible
            } else if error.code == .authFailed || error.code == .notPaired {
                connectionState = .needsPairing
                if let selected { preferences?.rejectedServers.insert(selected.id) }
                refreshDiscovery()
            } else {
                connectionState = .failed
            }
            if wasPairing { pairingMessage = failureMessage }
        case .network(.dns(-65570)):
            cancelRetries()
            connectionState = .failed
            failureMessage = L10n.text("Allow Kinrox local network access in iPhone Settings.")
            discoveryStatus = .permissionDenied
        case .invalidMessage, .messageTooLarge, .nonLocalEndpoint, .invalidService:
            cancelRetries()
            connectionState = .failed
            failureMessage = L10n.text(
                "Failed to establish secure connection to Mac on local network.")
        default:
            if wasPairing {
                cancelRetries()
                connectionState = .failed
                failureMessage = L10n.text("Connection interrupted. Request a new code.")
            } else {
                scheduleRetry()
            }
        }
        logger.info("Connection terminated: \(failure.diagnosticCode, privacy: .public)")
    }

    func scheduleRetry() {
        guard foreground, selected != nil else { return }
        connectionState = .reconnecting
        startRetryDeadline()
        guard retryTimer == nil else { return }
        nextRetryDelay = RemoteRetryPolicy.delay(at: retryAttempt)
        retryAttempt += 1
        retryTimer = scheduler.schedule(after: nextRetryDelay) { [weak self] in
            guard let self, self.foreground else { return }
            self.retryTimer = nil
            self.attemptConnection(pair: false)
        }
    }

    func startRetryDeadline() {
        guard retryDeadline == nil else { return }
        retryDeadline = scheduler.schedule(after: RemoteRetryPolicy.timeout) { [weak self] in
            guard let self else { return }
            self.cancelConnection()
            self.connectionState = .failed
            self.failureMessage = L10n.text(
                "Failed to connect within two minutes. Check Mac and network.")
        }
    }

    func retryConnection() {
        guard foreground else { return }
        let pair = screen == .pairing || pairingAttempt
        cancelConnection()
        failureMessage = nil
        if discovery?.state != .ready
            || discovery?.servers.contains(where: { $0.id == selected?.id && $0.isAvailable })
                != true
        {
            retryDiscovery()
        }
        if pair { beginPairing() } else { restoreSelected() }
    }

    func detachClient(gracefully: Bool = false) {
        waitingForDiscovery = false
        frozenPosition = position
        hasState = false
        scrubTarget = nil
        epoch = UUID()
        volumeTimer?.cancel()
        volumeTimer = nil
        pendingVolume = nil
        lastVolumeSent = -Double.infinity
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        let cancelled = Array(pending.values)
        pending.removeAll()
        for request in cancelled {
            request.timeout.cancel()
            request.completion?(false)
        }
        let previous = client
        client = nil
        previous?.onStateChange = nil
        previous?.onEvent = nil
        retirement?.cancel()
        retirement = nil
        retiringClient?.close(.closed)
        retiringClient = nil
        backgroundLease?.end()
        backgroundLease = nil
        guard let previous else { return }
        if gracefully, connectionState == .connected {
            retiringClient = previous
            // Even stalled bye transmission does not hold socket after entering background.
            if monitorNetwork {
                backgroundLease = RemoteBackgroundLease { [weak self] in
                    self?.finishRetirement(previous)
                }
            }
            retirement = scheduler.schedule(after: 0.25) { [weak self] in
                self?.finishRetirement(previous)
            }
            Task { [weak self] in
                try? await previous.send(.bye(.init()))
                guard let self else {
                    previous.close(.closed)
                    return
                }
                self.finishRetirement(previous)
            }
        } else {
            previous.close(.closed)
        }
    }

    func finishRetirement(_ previous: any RemoteConnection) {
        guard retiringClient === previous else { return }
        retirement?.cancel()
        retirement = nil
        retiringClient = nil
        previous.close(.closed)
        backgroundLease?.end()
        backgroundLease = nil
    }

    func cancelRetries() {
        retryTimer?.cancel()
        retryTimer = nil
        retryDeadline?.cancel()
        retryDeadline = nil
        retryAttempt = 0
        nextRetryDelay = 0
    }
    func cancelConnection(gracefully: Bool = false) {
        cancelRetries()
        detachClient(gracefully: gracefully)
    }

    func enterBackground() {
        guard foreground else { return }
        foreground = false
        cancelConnection(gracefully: true)
        connectionState = .idle
        hintTimer?.cancel()
        hintTimer = nil
        discovery?.stop()
        networkMonitor?.stop()
        networkMonitor = nil
    }

    func enterForeground() {
        guard started else {
            start()
            return
        }
        guard !foreground else { return }  // inactive does not close connection.
        foreground = true
        if isDemo {
            if screen == .remote { connectionState = .connected }
            syncDemo()
            return
        }
        startDiscovery()
        if screen == .pairing {
            beginPairing()
        } else if selected != nil {
            restoreSelected()
        }
    }

    func stop() {
        foreground = false
        cancelConnection()
        hintTimer?.cancel()
        hintTimer = nil
        discovery?.onChange = nil
        discovery?.stop()
        networkMonitor?.stop()
        networkMonitor = nil
    }

    static func message(for error: ProtocolError) -> String {
        switch error.code {
        case .authFailed, .notPaired:
            L10n.text("Mac access is no longer verified. Connect again using code.")
        case .incompatibleVersion:
            L10n.text("Kinrox versions incompatible. Update Mac player and iPhone remote.")
        case .pairingTimeout: L10n.text("Code expired. Request a new code.")
        case .tooManyAttempts: L10n.text("No attempts remaining. Request a new code.")
        case .pairingRejected: L10n.text("Pairing rejected. Request a new code.")
        case .noMedia: L10n.text("Nothing is playing on Mac.")
        case .itemNotFound: L10n.text("File not found on Mac.")
        default: L10n.text("Mac could not complete request. Try again.")
        }
    }
}
