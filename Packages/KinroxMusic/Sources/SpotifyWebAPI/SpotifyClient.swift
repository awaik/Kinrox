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
    private var scheduler = SpotifyRequestScheduler()
    private struct SharedRead {
        let id: UUID
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<SpotifyHTTPResponse, any Error>]
    }
    private var reads: [String: SharedRead] = [:]

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
        scheduler.close()
        // Foundation raises an Objective-C exception when a task is created in an
        // invalidated session. Let already-entered calls unwind before invalidation.
        if inFlight == 0 { session.invalidateAndCancel() }
    }

    func request(
        _ path: String, method: String = "GET", query: [String: String] = [:], body: Data? = nil,
        priority: SpotifyRequestPriority? = nil, live: Bool = false
    ) async throws -> Data {
        try await response(
            path, method: method, query: query, body: body,
            priority: priority, live: live
        ).data
    }

    func response(
        _ path: String, method: String = "GET", query: [String: String] = [:], body: Data? = nil,
        etag: String? = nil, priority: SpotifyRequestPriority? = nil, live: Bool = false
    ) async throws -> SpotifyHTTPResponse {
        guard !isClosed else { throw CancellationError() }
        try Task.checkCancellation()
        let url = try Self.url(path, query: query)
        let control = url.path.hasPrefix("/v1/me/player")
        let priority = control ? .control : priority ?? SpotifyRequestContext.priority
        let coalesces = method == "GET" && !control && !live
        let key = url.absoluteString + "|" + (etag ?? "") + "|" + SpotifyRequestContext.revision
        guard coalesces else {
            return try await perform(
                url, method: method, body: body, etag: etag, priority: priority)
        }
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if reads[key] != nil {
                    reads[key]?.subscribers[subscriber] = continuation
                } else {
                    let id = UUID()
                    let task = Task {
                        let result: Result<SpotifyHTTPResponse, any Error>
                        do {
                            result = .success(
                                try await self.perform(
                                    url, method: method, body: body, etag: etag, priority: priority)
                            )
                        } catch {
                            result = .failure(error)
                        }
                        self.finishRead(key, id: id, result: result)
                    }
                    reads[key] = SharedRead(
                        id: id, task: task, subscribers: [subscriber: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelRead(key, subscriber: subscriber) }
        }
    }

    private func finishRead(
        _ key: String, id: UUID, result: Result<SpotifyHTTPResponse, any Error>
    ) {
        guard let read = reads[key], read.id == id else { return }
        reads[key] = nil
        for continuation in read.subscribers.values { continuation.resume(with: result) }
    }

    private func cancelRead(_ key: String, subscriber: UUID) {
        guard let continuation = reads[key]?.subscribers.removeValue(forKey: subscriber) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if let read = reads[key], read.subscribers.isEmpty {
            reads[key] = nil
            read.task.cancel()
        }
    }

    private func acquire(_ priority: SpotifyRequestPriority) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                scheduler.enqueue(.init(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }
    private func cancelWaiting(_ id: UUID) { scheduler.cancel(id) }

    private func checkCooldown() throws {
        guard !isClosed else { throw CancellationError() }
        if case .rateLimited(let until, _) = cooldown, until > now(), let cooldown {
            throw cooldown
        }
        cooldown = nil
    }

    private func perform(
        _ url: URL, method: String, body: Data?, etag: String?, priority: SpotifyRequestPriority
    ) async throws -> SpotifyHTTPResponse {
        inFlight += 1
        defer {
            inFlight -= 1
            if isClosed && inFlight == 0 { session.invalidateAndCancel() }
        }
        try checkCooldown()
        try await acquire(priority)
        defer { scheduler.release(priority) }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            try checkCooldown()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.httpBody = body
            request.setValue(
                "Bearer " + (try await token(attempt == 1)), forHTTPHeaderField: "Authorization")
            try checkCooldown()
            try Task.checkCancellation()
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            guard !isClosed else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else {
                throw SpotifyError.invalidResponse
            }
            if (200..<300).contains(http.statusCode) || (http.statusCode == 304 && etag != nil) {
                return SpotifyHTTPResponse(
                    data: data, etag: http.value(forHTTPHeaderField: "ETag") ?? etag,
                    notModified: http.statusCode == 304)
            }
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

    public func resource<T: Decodable & Sendable>(
        _ type: T.Type, path: String, etag: String? = nil
    ) async throws -> SpotifyResource<T> {
        let response = try await response(path, etag: etag)
        return SpotifyResource(
            value: response.notModified ? nil : try JSONDecoder().decode(type, from: response.data),
            etag: response.etag)
    }

    public func resourcePages<T: Decodable & Sendable>(
        _ type: T.Type, path: String, etag: String? = nil
    ) async throws -> SpotifyResource<[T]> {
        let first = try await resource(SpotifyPage<T>.self, path: path, etag: etag)
        guard let page = first.value else { return SpotifyResource(value: nil, etag: first.etag) }
        var items = page.items
        if let next = page.next { items += try await pages(type, next) }
        return SpotifyResource(value: items, etag: page.next == nil ? first.etag : nil)
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
        parts.queryItems = parts.queryItems?.sorted {
            $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
        }
        guard let url = parts.url else { throw SpotifyError.invalidURL }
        return url
    }
}
