import Foundation

public actor MetaBrainzClient {
    public enum Failure: Error { case invalidURL, unavailable }
    static let artistAlgorithm =
        "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"
    static let recordingAlgorithm =
        "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30"
    private let session: URLSession
    private let limiter: MusicBrainzRateLimiter
    private let cache: (any MetaBrainzCache)?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var memory: [String: (Date, Data)] = [:]

    public init(
        version: String, configuration: URLSessionConfiguration = .ephemeral,
        cache: (any MetaBrainzCache)? = nil,
        limiter: MusicBrainzRateLimiter = MusicBrainzRateLimiter(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "Kinrox/\(version) ( https://kinrox.app )", "Accept": "application/json",
        ]
        session = URLSession(
            configuration: config, delegate: MetaBrainzRedirectPolicy(), delegateQueue: nil)
        self.cache = cache
        self.limiter = limiter
        self.now = now
        self.sleep = sleep
    }

    public func close() {
        memory.removeAll()
        session.invalidateAndCancel()
    }

    public func resolve(
        trackID: String?, isrc: String?, title: String, artistID: String?, artistName: String,
        needsGenres: Bool
    ) async throws -> MetaBrainzResolution {
        let key =
            "resolution|\(trackID ?? "")|\(isrc ?? "")|\(artistID ?? "")|\(Self.normalized(artistName))|\(needsGenres)"
        if let value: MetaBrainzResolution = try await cached(key) { return value }
        var result = MetaBrainzResolution(recordingMBID: nil, artists: [], genres: [])
        if let isrc, !isrc.isEmpty,
            let data = try await request(
                host: "musicbrainz.org", path: "/ws/2/isrc/" + Self.identifier(isrc),
                query: ["inc": "artist-credits", "fmt": "json"])
        {
            let records = try JSONDecoder().decode(MusicBrainzISRC.self, from: data).recordings
            if let record = records.first {
                result.recordingMBID = record.id
                result.artists = record.credits.map(\.artist)
            }
        }
        if result.recordingMBID == nil, !title.isEmpty, !artistName.isEmpty {
            do {
                let recordings: [MetaBrainzRecording] =
                    try await read(
                        host: "labs.api.listenbrainz.org", path: "/recording-search/json",
                        query: ["query": artistName + " " + title]) ?? []
                result.recordingMBID =
                    recordings.first {
                        Self.normalized($0.artistCreditName) == Self.normalized(artistName)
                            && Self.normalized($0.recordingName) == Self.normalized(title)
                    }?.recordingMBID
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                // Labs is experimental; stable artist/genre resolution remains useful.
                try Task.checkCancellation()
            }
        }
        if result.artists.isEmpty, !artistName.isEmpty {
            let artistKey = "artist|\(artistID ?? "")|\(Self.normalized(artistName))"
            if let artists: [MetaBrainzArtist] = try await cached(artistKey) {
                result.artists = artists
            } else {
                let response: MusicBrainzArtists? = try await read(
                    host: "musicbrainz.org", path: "/ws/2/artist/",
                    query: ["query": "artist:\"\(artistName)\"", "fmt": "json", "limit": "3"])
                result.artists = Array(
                    (response?.artists ?? []).filter {
                        Self.normalized($0.name) == Self.normalized(artistName)
                    }.prefix(1))
                try await save(artistKey, value: result.artists, ttl: 30 * 86400)
            }
        }
        if needsGenres, let artist = result.artists.first {
            let genreKey = "genres|" + artist.id
            if let genres: [String] = try await cached(genreKey) {
                result.genres = genres
            } else {
                let response: MusicBrainzGenres? = try await read(
                    host: "musicbrainz.org", path: "/ws/2/artist/" + Self.identifier(artist.id),
                    query: ["inc": "genres", "fmt": "json"])
                result.genres = Array(
                    (response?.genres ?? []).sorted {
                        $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
                    }.prefix(6).map(\.name))
                try await save(genreKey, value: result.genres, ttl: 30 * 86400)
            }
        }
        try await save(key, value: result, ttl: 30 * 86400)
        return result
    }

    public func similarArtists(_ mbid: String) async throws -> [MetaBrainzSimilarArtist] {
        let key = "artists|" + mbid
        if let result: [MetaBrainzSimilarArtist] = try await cached(key) { return result }
        let result: [MetaBrainzSimilarArtist] =
            try await read(
                host: "labs.api.listenbrainz.org", path: "/similar-artists/json",
                query: ["artist_mbids": mbid, "algorithm": Self.artistAlgorithm]) ?? []
        let top = Array(result.sorted { $0.score > $1.score }.prefix(15))
        try await save(key, value: top, ttl: 7 * 86400)
        return top
    }

    public func similarRecordings(_ mbid: String) async throws -> [MetaBrainzRecording] {
        let key = "recordings|" + mbid
        if let result: [MetaBrainzRecording] = try await cached(key) { return result }
        let result: [MetaBrainzRecording] =
            try await read(
                host: "labs.api.listenbrainz.org", path: "/similar-recordings/json",
                query: ["recording_mbids": mbid, "algorithm": Self.recordingAlgorithm]) ?? []
        let top = Array(result.sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(50))
        try await save(key, value: top, ttl: 7 * 86400)
        return top
    }

    public func spotifyIDs(_ mbids: [String]) async throws -> [MetaBrainzSpotifyMapping] {
        guard !mbids.isEmpty else { return [] }
        let ids = Array(mbids.prefix(50)).sorted()
        let key = "mapping|" + ids.joined(separator: ",")
        if let result: [MetaBrainzSpotifyMapping] = try await cached(key) { return result }
        let body = try JSONEncoder().encode(ids.map { ["recording_mbid": $0] })
        let data =
            try await request(
                host: "labs.api.listenbrainz.org", path: "/spotify-id-from-mbid/json", body: body)
            ?? Data("[]".utf8)
        let result = try JSONDecoder().decode([MetaBrainzSpotifyMapping].self, from: data)
        try await save(key, value: result, ttl: 7 * 86400)
        return result
    }

    private func cached<T: Decodable>(_ key: String) async throws -> T? {
        try Task.checkCancellation()
        if let (expiry, data) = memory[key], expiry > now() {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        if let data = try? await cache?.readMetaBrainz(key) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return nil
    }
    private func save<T: Encodable>(_ key: String, value: T, ttl: TimeInterval) async throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(value)
        memory = memory.filter { $0.value.0 > now() }
        if memory.count >= 256 {
            memory.removeValue(forKey: memory.min { $0.value.0 < $1.value.0 }!.key)
        }
        memory[key] = (now().addingTimeInterval(ttl), data)
        try? await cache?.writeMetaBrainz(key, data: data, ttl: ttl)
    }
    private func read<T: Decodable>(host: String, path: String, query: [String: String])
        async throws -> T?
    {
        guard let data = try await request(host: host, path: path, query: query) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func request(
        host: String, path: String, query: [String: String] = [:], body: Data? = nil
    ) async throws -> Data? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.queryItems = query.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let url = parts.url, ["musicbrainz.org", "labs.api.listenbrainz.org"].contains(host)
        else { throw Failure.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let captured = request
        for attempt in 0...1 {
            try Task.checkCancellation()
            let result: (Data, URLResponse)
            if host == "musicbrainz.org" {
                result = try await limiter.perform { [session] in
                    try await session.data(for: captured)
                }
            } else {
                result = try await session.data(for: captured)
            }
            guard let response = result.1 as? HTTPURLResponse else { throw Failure.unavailable }
            if response.statusCode == 404 { return nil }
            if response.statusCode == 503, host == "musicbrainz.org", attempt == 0 {
                try await sleep(
                    Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: now()))
                continue
            }
            guard response.statusCode == 200 else { throw Failure.unavailable }
            return result.0
        }
        throw Failure.unavailable
    }
    static func retryDelay(_ raw: String?, now: Date) -> TimeInterval {
        if let raw, let seconds = Double(raw) { return min(5, max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return min(5, max(0, raw.flatMap(formatter.date(from:))?.timeIntervalSince(now) ?? 1))
    }
    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(
            separator: " ")
    }
    static func identifier(_ value: String) throws -> String {
        guard !value.isEmpty,
            value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            )
        else { throw Failure.invalidURL }
        return value
    }
}

private final class MetaBrainzRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
