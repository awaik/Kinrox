import CryptoKit
import Foundation

public struct SpotifyAuthorization: Sendable {
    public static let redirect = "http://127.0.0.1:43821/callback"
    public static let scopes = [
        "user-library-read", "user-library-modify", "user-follow-read", "user-follow-modify",
        "playlist-read-private", "playlist-read-collaborative", "playlist-modify-private",
        "playlist-modify-public", "user-read-playback-state",
    ].joined(separator: " ")
    public let verifier: String
    public let state: String
    public let clientID: String

    public init(clientID: String) throws {
        guard clientID.count == 32, clientID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw SpotifyError.authentication
        }
        self.clientID = clientID
        verifier = Self.random()
        state = Self.random()
    }

    public var url: URL {
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(
                name: "code_challenge",
                value: Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))),
        ]
        return url.url!
    }

    public func code(from url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "http", parts.host == "127.0.0.1", parts.port == 43821,
            parts.path == "/callback", parts.fragment == nil, parts.user == nil,
            parts.password == nil,
            parts.queryItems?.filter({ $0.name == "state" }).count == 1,
            parts.queryItems?.first(where: { $0.name == "state" })?.value == state,
            parts.queryItems?.contains(where: { $0.name == "error" }) != true,
            parts.queryItems?.filter({ $0.name == "code" }).count == 1,
            let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw SpotifyError.authentication }
        return code
    }

    public func wasDenied(at url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "http", parts.host == "127.0.0.1", parts.port == 43821,
            parts.path == "/callback", parts.fragment == nil, parts.user == nil,
            parts.password == nil,
            parts.queryItems?.filter({ $0.name == "state" }).count == 1,
            parts.queryItems?.first(where: { $0.name == "state" })?.value == state,
            parts.queryItems?.filter({ $0.name == "error" }).count == 1,
            parts.queryItems?.first(where: { $0.name == "error" })?.value == "access_denied",
            parts.queryItems?.contains(where: { $0.name == "code" }) != true
        else { return false }
        return true
    }

    private static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64(Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct SpotifyTokens: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Double
}

public enum SpotifyOAuth {
    public static func exchange(
        code: String, authorization: SpotifyAuthorization,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> SpotifyTokens {
        try await tokens(
            [
                "grant_type": "authorization_code", "code": code,
                "client_id": authorization.clientID,
                "redirect_uri": SpotifyAuthorization.redirect,
                "code_verifier": authorization.verifier,
            ], configuration: configuration)
    }

    public static func refresh(
        _ refreshToken: String, clientID: String,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> SpotifyTokens {
        try await tokens(
            ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID],
            configuration: configuration)
    }

    private static func tokens(_ values: [String: String], configuration: URLSessionConfiguration)
        async throws -> SpotifyTokens
    {
        let session = URLSession(
            configuration: configuration, delegate: SpotifyRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.invalidResponse }
        if http.statusCode == 400 || http.statusCode == 401 { throw SpotifyError.authentication }
        guard http.statusCode == 200 else { throw SpotifyError.unavailable }
        let tokens = try JSONDecoder().decode(SpotifyTokens.self, from: data)
        guard !tokens.accessToken.isEmpty, tokens.expiresIn.isFinite, tokens.expiresIn > 0 else {
            throw SpotifyError.invalidResponse
        }
        return tokens
    }
}
