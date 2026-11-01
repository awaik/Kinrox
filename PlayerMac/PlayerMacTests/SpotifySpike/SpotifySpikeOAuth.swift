import AppKit
import CryptoKit
import Foundation
import Security

/// Phase 0 only. Compiled into the test bundle, never the application.
@MainActor
enum SpotifySpikeOAuth {
    static let redirect = "http://127.0.0.1:43821/callback"
    static let scopes = [
        "user-library-read", "user-library-modify", "user-follow-read", "user-follow-modify",
        "playlist-read-private", "playlist-read-collaborative", "playlist-modify-private",
        "playlist-modify-public", "user-read-playback-state", "user-modify-playback-state",
    ].joined(separator: " ")

    struct Token: Decodable {
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }

        let accessToken: String
        let refreshToken: String?
    }

    static func authorize(clientID: String) async throws -> String {
        if let refresh = try storedRefresh(clientID) {
            let token = try await exchange([
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
            ])
            try saveRefresh(token.refreshToken ?? refresh, clientID: clientID)
            return token.accessToken
        }
        let verifier = try randomString()
        let state = try randomString()
        let challenge = base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        let receiver = try SpotifySpikeLoopback(state: state)
        let code = try await receiver.receive(authorizationURL: components.url!)
        let token = try await exchange([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "redirect_uri": redirect, "code_verifier": verifier,
        ])
        guard let refresh = token.refreshToken else { throw SpotifySpikeFailure.invalidResponse }
        try saveRefresh(refresh, clientID: clientID)
        return token.accessToken
    }

    private static func exchange(_ values: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(
            values.sorted { $0.key < $1.key }.map {
                $0.key + "="
                    + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&").utf8)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifySpikeFailure.authentication
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SpotifySpikeFailure.authentication
        }
        return base64(Data(bytes))
    }

    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func query(_ clientID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.kinrox.spotify.phase0",
            kSecAttrAccount as String: clientID,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func storedRefresh(_ clientID: String) throws -> String? {
        var request = query(clientID)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else { throw SpotifySpikeFailure.keychain(status) }
        return token
    }

    private static func saveRefresh(_ token: String, clientID: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = query(clientID)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SpotifySpikeFailure.keychain(status) }
    }
}

enum SpotifySpikeFailure: Error {
    case authentication, invalidResponse, timeout
    case keychain(OSStatus)
    case http(status: Int, retryAfter: String?, quotaExceeded: Bool)
}
