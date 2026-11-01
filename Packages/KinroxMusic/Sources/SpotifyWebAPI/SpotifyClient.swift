import Foundation

public enum SpotifyError: Error, Equatable, Sendable {
    case authentication, forbidden, unavailable, invalidResponse, invalidURL, noDevice
    case rateLimited(until: Date, quotaExceeded: Bool)
    case http(Int)
}

/// Never follows redirects carrying a bearer token. Paging URLs are origin checked too.
final class SpotifyRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Single account client. Authentication and cooldown are shared by all endpoint calls.
public actor SpotifyClient {
    public typealias AccessToken = @Sendable (_ forceRefresh: Bool) async throws -> String
    private let token: AccessToken
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cooldown: SpotifyError?
    private var isClosed = false
    private var inFlight = 0

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        now: @escaping @Sendable () -> Date = { Date() }, token: @escaping AccessToken
    ) {
        self.token = token
        self.now = now
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(
            configuration: configuration, delegate: SpotifyRedirectPolicy(), delegateQueue: nil)
    }

    public func close() {
        isClosed = true
        // Foundation raises an Objective-C exception when a task is created in an
        // invalidated session. Let already-entered calls unwind before invalidation.
        if inFlight == 0 { session.invalidateAndCancel() }
    }

    func request(
        _ path: String, method: String = "GET", query: [String: String] = [:], body: Data? = nil
    ) async throws -> Data {
        guard !isClosed else { throw CancellationError() }
        inFlight += 1
        defer {
            inFlight -= 1
            if isClosed && inFlight == 0 { session.invalidateAndCancel() }
        }
        if case .rateLimited(let until, _) = cooldown, until > now(), let cooldown {
            throw cooldown
        }
        cooldown = nil
        let url = try Self.url(path, query: query)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.httpBody = body
            request.setValue(
                "Bearer " + (try await token(attempt == 1)), forHTTPHeaderField: "Authorization")
            guard !isClosed else { throw CancellationError() }
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            guard !isClosed else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else {
                throw SpotifyError.invalidResponse
            }
            if (200..<300).contains(http.statusCode) { return data }
            switch http.statusCode {
            case 401:
                if attempt == 0 { continue }
                throw SpotifyError.authentication
            case 403: throw SpotifyError.forbidden
            case 404:
                throw url.path.hasPrefix("/v1/me/player")
                    ? SpotifyError.noDevice : SpotifyError.http(404)
            case 429:
                let quota = String(data: data, encoding: .utf8)?.contains("QUOTA_EXCEEDED") == true
                let seconds = max(
                    1,
                    Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
                        ?? (quota ? 3600 : 30))
                let error = SpotifyError.rateLimited(
                    until: now().addingTimeInterval(seconds), quotaExceeded: quota)
                cooldown = error
                throw error
            case 500...599: throw SpotifyError.unavailable
            default: throw SpotifyError.http(http.statusCode)
            }
        }
        throw SpotifyError.authentication
    }

    func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String] = [:])
        async throws -> T
    {
        let data = try await request(path, query: query)
        return try JSONDecoder().decode(type, from: data)
    }

    func pages<T: Decodable & Sendable>(_ type: T.Type, _ path: String) async throws -> [T] {
        var next: String? = path
        var visited = Set<String>()
        var result: [T] = []
        while let path = next {
            guard visited.insert(path).inserted, visited.count <= 2000 else {
                throw SpotifyError.invalidResponse
            }
            let page = try await get(SpotifyPage<T>.self, path)
            result += page.items
            next = page.next
        }
        return result
    }

    static func url(_ path: String, query: [String: String]) throws -> URL {
        guard
            var parts = URLComponents(
                string: path.hasPrefix("https://") ? path : "https://api.spotify.com/v1/" + path),
            parts.scheme == "https", parts.host == "api.spotify.com", parts.port == nil,
            parts.user == nil, parts.password == nil, parts.path.hasPrefix("/v1/"),
            parts.fragment == nil
        else { throw SpotifyError.invalidURL }
        if !query.isEmpty {
            parts.queryItems =
                (parts.queryItems ?? [])
                + query.sorted { $0.key < $1.key }.map {
                    URLQueryItem(name: $0.key, value: $0.value)
                }
        }
        guard let url = parts.url else { throw SpotifyError.invalidURL }
        return url
    }
}
