import Foundation
import Observation
import SpotifyWebAPI

@MainActor @Observable
final class SpotifyAccount {
    var clientID: String {
        didSet { if clientID != oldValue && !connected { onInteractiveConnection?() } }
    }
    var termsAccepted: Bool
    static let consentPreference = "app.kinrox.spotify.acceptedTerms"
    private(set) var accountName: String?
    private(set) var userID: String?
    private(set) var isConnecting = false
    private(set) var client: SpotifyClient?
    var errorMessage: String?
    var onConnected: ((SpotifyClient, SpotifyProfile, SpotifyCacheStore) async -> Void)?
    var onInteractiveConnection: (() -> Void)?
    var onRestore: ((SpotifyClient, SpotifyAccountBinding, SpotifyCacheStore) async -> Void)?
    var onRestoreFailed: ((String) -> Void)?
    private(set) var cache: SpotifyCacheStore?
    private var pendingClient: SpotifyClient?
    static let bindingPreference = "app.kinrox.spotify.verifiedAccount"
    var onDisconnected: (() -> Void)?
    var beforeDisconnect: (() async throws -> Void)?
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
            SpotifyDocuments.bundled != nil
        else {
            return
        }
        guard defaults.string(forKey: Self.consentPreference) == SpotifyDocuments.currentVersion
        else {
            let message = L10n.text("Reconnect Spotify in Settings.")
            errorMessage = message
            onRestoreFailed?(message)
            return
        }
        begin(interactive: false)
    }
    func connect() {
        guard !connected, !isConnecting, termsAccepted, SpotifyDocuments.bundled != nil else {
            return
        }
        defaults.set(SpotifyDocuments.currentVersion, forKey: Self.consentPreference)
        onInteractiveConnection?()
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
                let client = SpotifyClient { [weak self] force in
                    guard let self else { throw SpotifyError.authentication }
                    return try await self.accessToken(force: force, generation: generation)
                }
                self.pendingClient = client
                if !interactive, try self.credentials.refreshToken(clientID: id) != nil,
                    let data = self.defaults.data(forKey: Self.bindingPreference),
                    let binding = try? JSONDecoder().decode(SpotifyAccountBinding.self, from: data),
                    binding.clientID == id
                {
                    let cache = SpotifyCacheStore(
                        clientID: id, userID: binding.userID, displayName: binding.accountName)
                    self.cache = cache
                    await self.onRestore?(client, binding, cache)
                    guard self.generation == generation else { throw CancellationError() }
                }
                let tokens = try await self.authenticate(
                    authorization, interactive: interactive, generation: generation)
                guard self.generation == generation else { throw CancellationError() }
                self.activeClientID = id
                self.install(tokens)
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
                let binding = SpotifyAccountBinding(
                    clientID: id, userID: profile.id, accountName: self.accountName ?? profile.id)
                self.defaults.set(try JSONEncoder().encode(binding), forKey: Self.bindingPreference)
                if self.cache?.userID != profile.id || self.cache?.clientID != id {
                    if let previous = self.cache { try? await previous.destroyAccountCache() }
                    guard self.generation == generation else { throw CancellationError() }
                    self.cache = SpotifyCacheStore(
                        clientID: id, userID: profile.id, displayName: binding.accountName)
                }
                if let cache = self.cache { await self.onConnected?(client, profile, cache) }
                self.pendingClient = nil
            } catch is CancellationError {
                // Closing the connection flow is an intentional cancellation.
            } catch {
                guard self.generation == generation else { return }
                let message = SpotifyStatus.message(error)
                self.errorMessage = message
                if !interactive { self.onRestoreFailed?(message) }
                if let client = self.pendingClient { await client.close() }
                self.pendingClient = nil
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
        connectionTask?.cancel()
        receiver?.cancel()
        if client == nil { generation = UUID() }
        isConnecting = true
        isDisconnecting = true
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.beforeDisconnect?() } catch {
                self.errorMessage = SpotifyStatus.message(error)
                self.isConnecting = false
                self.isDisconnecting = false
                return
            }
            if let client = self.client { await client.close() }
            if let client = self.pendingClient { await client.close() }
            self.pendingClient = nil
            if let cache = self.cache {
                do { try await cache.destroyAccountCache() } catch {
                    self.errorMessage = SpotifyStatus.message(error)
                }
            }
            self.cache = nil
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
        defaults.removeObject(forKey: Self.bindingPreference)
        // Retain non-secret legacy playlist IDs as exclusion tombstones. Disconnect must not
        // make old Kinrox Queue playlists eligible for subsequent bulk favorite mutations.
        if let id = activeClientID ?? (clientID.isEmpty ? nil : clientID) {
            do { try credentials.remove(clientID: id) } catch {
                errorMessage = SpotifyStatus.message(error)
            }
        }
        activeClientID = nil
        onDisconnected?()
    }
}

struct SpotifyAccountBinding: Codable, Sendable {
    let clientID: String
    let userID: String
    let accountName: String
}
