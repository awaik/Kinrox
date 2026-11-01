import Foundation
import Observation
import SpotifyWebAPI

@MainActor @Observable
final class SpotifyAccount {
    var clientID: String
    var termsAccepted: Bool
    static let consentPreference = "app.kinrox.spotify.acceptedTerms"
    private(set) var accountName: String?
    private(set) var userID: String?
    private(set) var isConnecting = false
    private(set) var client: SpotifyClient?
    var errorMessage: String?
    var onConnected: ((SpotifyClient) -> Void)?
    var onDisconnected: (() -> Void)?
    var beforeDisconnect: (() async -> Void)?
    private let credentials: any SpotifyCredentialStore
    private let defaults: UserDefaults
    private var activeClientID: String?
    private var cachedToken: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<SpotifyTokens, any Error>?
    private var connectionTask: Task<Void, Never>?
    private var receiver: SpotifyLoopback?
    private var generation = UUID()
    private var isDisconnecting = false
    static let preference = "app.kinrox.spotify.clientID"
    static let queuePreferencePrefix = "app.kinrox.spotify.queue."

    init(
        credentials: any SpotifyCredentialStore = KeychainSpotifyCredentialStore(),
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.defaults = defaults
        termsAccepted =
            defaults.string(forKey: Self.consentPreference) == SpotifyDocuments.currentVersion
        clientID = defaults.string(forKey: Self.preference) ?? ""
    }

    var connected: Bool { client != nil }
    var hasStoredConnection: Bool { defaults.string(forKey: Self.preference) != nil }

    /// Only runs after a prior, successful explicit connection. Fresh installs make no requests.
    func restore() {
        guard defaults.string(forKey: Self.preference) != nil, !isConnecting, !connected,
            defaults.string(forKey: Self.consentPreference) == SpotifyDocuments.currentVersion,
            SpotifyDocuments.bundled != nil
        else {
            return
        }
        begin(interactive: false)
    }
    func connect() {
        guard !connected, !isConnecting, termsAccepted, SpotifyDocuments.bundled != nil else {
            return
        }
        defaults.set(SpotifyDocuments.currentVersion, forKey: Self.consentPreference)
        begin(interactive: true)
    }

    private func begin(interactive: Bool) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let authorization = try? SpotifyAuthorization(clientID: id) else {
            errorMessage = L10n.text("Enter a valid Spotify Client ID.")
            return
        }
        let generation = UUID()
        self.generation = generation
        isConnecting = true
        errorMessage = nil
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.isConnecting = false
                    self.receiver = nil
                }
            }
            do {
                let tokens = try await self.authenticate(
                    authorization, interactive: interactive, generation: generation)
                guard self.generation == generation else { throw CancellationError() }
                self.activeClientID = id
                self.install(tokens)
                let client = SpotifyClient { [weak self] force in
                    guard let self else { throw SpotifyError.authentication }
                    return try await self.accessToken(force: force, generation: generation)
                }
                let profile = try await client.profile()
                guard self.generation == generation else {
                    await client.close()
                    return
                }
                self.clientID = id
                self.accountName = profile.displayName ?? profile.id
                self.userID = profile.id
                self.client = client
                self.defaults.set(id, forKey: Self.preference)
                self.onConnected?(client)
            } catch is CancellationError {
                // Closing the connection flow is an intentional cancellation.
            } catch {
                guard self.generation == generation else { return }
                self.errorMessage = SpotifyStatus.message(error)
            }
        }
    }

    private func authenticate(
        _ authorization: SpotifyAuthorization, interactive: Bool, generation: UUID
    ) async throws -> SpotifyTokens {
        let id = authorization.clientID
        if let refresh = try credentials.refreshToken(clientID: id) {
            do {
                let tokens = try await SpotifyOAuth.refresh(refresh, clientID: id)
                guard self.generation == generation else { throw CancellationError() }
                try credentials.save(tokens.refreshToken ?? refresh, clientID: id)
                return tokens
            } catch SpotifyError.authentication where interactive {
                // An explicitly requested reconnect may replace a revoked refresh credential.
            }
        }
        guard interactive else { throw SpotifyError.authentication }
        let receiver = try SpotifyLoopback(authorization: authorization)
        self.receiver = receiver
        let code = try await receiver.receive(authorizationURL: authorization.url)
        let tokens = try await SpotifyOAuth.exchange(code: code, authorization: authorization)
        guard self.generation == generation, let refresh = tokens.refreshToken else {
            throw CancellationError()
        }
        try credentials.save(refresh, clientID: id)
        return tokens
    }

    func accessToken(force: Bool, generation: UUID) async throws -> String {
        guard self.generation == generation else { throw CancellationError() }
        guard let id = activeClientID else { throw SpotifyError.authentication }
        if !force, let cachedToken, expiry.timeIntervalSinceNow > 60 { return cachedToken }
        if let refreshTask {
            let token = try await refreshTask.value.accessToken
            guard self.generation == generation else { throw CancellationError() }
            return token
        }
        guard let refresh = try credentials.refreshToken(clientID: id) else {
            throw SpotifyError.authentication
        }
        let task = Task { try await SpotifyOAuth.refresh(refresh, clientID: id) }
        refreshTask = task
        defer { refreshTask = nil }
        let tokens = try await task.value
        guard generation == self.generation else { throw CancellationError() }
        try credentials.save(tokens.refreshToken ?? refresh, clientID: id)
        install(tokens)
        return tokens.accessToken
    }

    private func install(_ tokens: SpotifyTokens) {
        cachedToken = tokens.accessToken
        expiry = Date().addingTimeInterval(tokens.expiresIn)
    }

    func disconnect() {
        guard !isDisconnecting else { return }
        guard !isConnecting else {
            finishDisconnect()
            return
        }
        isConnecting = true
        isDisconnecting = true
        connectionTask = Task { [weak self] in
            guard let self else { return }
            await self.beforeDisconnect?()
            self.finishDisconnect()
        }
    }

    private func finishDisconnect() {
        generation = UUID()
        receiver?.cancel()
        receiver = nil
        connectionTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        if let client { Task { await client.close() } }
        client = nil
        cachedToken = nil
        accountName = nil
        userID = nil
        isConnecting = false
        isDisconnecting = false
        defaults.removeObject(forKey: Self.preference)
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.queuePreferencePrefix) {
            defaults.removeObject(forKey: key)
        }
        if let id = activeClientID ?? (clientID.isEmpty ? nil : clientID) {
            do { try credentials.remove(clientID: id) } catch {
                errorMessage = SpotifyStatus.message(error)
            }
        }
        activeClientID = nil
        onDisconnected?()
    }
}
