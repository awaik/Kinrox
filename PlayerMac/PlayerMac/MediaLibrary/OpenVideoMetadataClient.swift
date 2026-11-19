import Foundation

actor OpenVideoMetadataClient {
    private let session: URLSession
    private let clock = ContinuousClock()
    private var nextRequest: ContinuousClock.Instant?

    init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(
            configuration: LibraryHTTP.configuration(configuration),
            delegate: NoMetadataRedirects(), delegateQueue: nil)
    }

    func lookup(_ title: VideoTitle) async throws -> MediaEnrichment? {
        guard !title.isPersonal, !title.title.isEmpty else { return nil }
        let series = title.season != nil
        do {
            if let result = try await cinemeta(title, series: series) { return result }
        } catch {
            try Task.checkCancellation()
            if series, let result = try await tvMaze(title) { return result }
            throw error
        }
        return series ? try await tvMaze(title) : nil
    }

    nonisolated static func searchURL(title: String, series: Bool) -> URL? {
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !title.contains(".."), title.utf8.count <= 350,
            let query = title.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }
        return URL(
            string:
                "https://v3-cinemeta.strem.io/catalog/\(series ? "series" : "movie")/top/search=\(query).json"
        )
    }

    private func cinemeta(_ title: VideoTitle, series: Bool) async throws -> MediaEnrichment? {
        guard let url = Self.searchURL(title: title.title, series: series) else { return nil }
        let matches: Catalog? = try await read(url)
        let normalized = MediaLibraryFile.normalized(title.title)
        let candidates =
            matches?.metas.filter { candidate in
                guard candidate.identifier?.wholeMatch(of: /tt[0-9]{5,12}/) != nil,
                    MediaLibraryFile.normalized(candidate.name) == normalized
                else { return false }
                guard let year = title.year else { return true }
                let reported = candidate.releaseInfo.flatMap { Int($0.prefix(4)) }
                return reported == nil || reported == year
            } ?? []
        guard let candidate = candidates.first, let id = candidate.identifier else { return nil }
        let type = series ? "series" : "movie"
        let detailsURL = URL(string: "https://v3-cinemeta.strem.io/meta/\(type)/\(id).json")!
        guard let details: Cinemeta = try await read(detailsURL) else { return nil }
        let meta = details.meta
        let year = meta.year?.text ?? meta.releaseInfo?.text ?? candidate.releaseInfo
        if let requested = title.year, let found = year.flatMap({ Int($0.prefix(4)) }),
            requested != found
        {
            return nil
        }
        return MediaEnrichment(
            title: meta.name, summary: meta.description,
            rating: MediaRatingScale.convert(meta.imdbRating?.number, from: 10, to: 10),
            source: .imdb, year: year, genres: meta.genres ?? meta.genre ?? [],
            posterURL: (meta.poster ?? candidate.poster).flatMap(URL.init(string:)),
            episodes: meta.videos?.compactMap {
                guard let season = $0.season, let episode = $0.episode, let name = $0.name else {
                    return nil
                }
                return MediaEnrichment.Episode(
                    season: season, number: episode, title: name, summary: $0.overview)
            } ?? [])
    }

    private func tvMaze(_ title: VideoTitle) async throws -> MediaEnrichment? {
        var url = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")!
        url.queryItems = [
            URLQueryItem(name: "q", value: title.title),
            URLQueryItem(name: "embed", value: "episodes"),
        ]
        guard let show: TVMazeShow = try await read(url.url!),
            MediaLibraryFile.normalized(show.name) == MediaLibraryFile.normalized(title.title)
        else { return nil }
        let year = show.premiered.map { String($0.prefix(4)) }
        if let requested = title.year, let found = year.flatMap(Int.init), found != requested {
            return nil
        }
        return MediaEnrichment(
            title: show.name, summary: show.summary.map(Self.plainText),
            rating: MediaRatingScale.convert(show.rating?.average, from: 10, to: 10),
            source: .tvmaze, year: year, genres: show.genres ?? [],
            posterURL: (show.image?.medium ?? show.image?.original).flatMap(URL.init(string:)),
            episodes: show._embedded?.episodes.compactMap {
                guard let number = $0.number else { return nil }
                return MediaEnrichment.Episode(
                    season: $0.season, number: number, title: $0.name,
                    summary: $0.summary.map(Self.plainText))
            } ?? [])
    }

    private func read<T: Decodable>(_ url: URL) async throws -> T? {
        guard url.scheme == "https", ["v3-cinemeta.strem.io", "api.tvmaze.com"].contains(url.host)
        else { throw URLError(.unsupportedURL) }
        try Task.checkCancellation()
        let slot = max(clock.now, nextRequest ?? clock.now)
        nextRequest = slot.advanced(by: .milliseconds(520))
        try await clock.sleep(until: slot)
        try Task.checkCancellation()
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200, response.expectedContentLength <= 8 << 20,
            data.count <= 8 << 20
        else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class NoMetadataRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

private struct Catalog: Decodable {
    struct Candidate: Decodable {
        let imdbID: String?
        let id: String?
        let name: String
        let releaseInfo: String?
        let poster: String?
        var identifier: String? { imdbID ?? id }

        enum CodingKeys: String, CodingKey {
            case imdbID = "imdb_id"
            case id, name, releaseInfo, poster
        }
    }
    let metas: [Candidate]
}

private struct Cinemeta: Decodable {
    struct Meta: Decodable {
        struct Video: Decodable {
            let season: Int?
            let episode: Int?
            let name: String?
            let overview: String?
        }
        let name: String
        let description: String?
        let imdbRating: FlexibleNumber?
        let year: FlexibleNumber?
        let releaseInfo: FlexibleNumber?
        let genre: [String]?
        let genres: [String]?
        let poster: String?
        let videos: [Video]?
    }
    let meta: Meta
}

private struct TVMazeShow: Decodable {
    struct Rating: Decodable { let average: Double? }
    struct Image: Decodable {
        let medium: String?
        let original: String?
    }
    struct Embedded: Decodable {
        struct Episode: Decodable {
            let season: Int
            let number: Int?
            let name: String
            let summary: String?
        }
        let episodes: [Episode]
    }
    let name: String
    let summary: String?
    let premiered: String?
    let rating: Rating?
    let genres: [String]?
    let image: Image?
    let _embedded: Embedded?
}

private struct FlexibleNumber: Decodable {
    let text: String?
    var number: Double? { text.flatMap(Double.init) }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            text = string
        } else if let integer = try? value.decode(Int.self) {
            text = String(integer)
        } else if let double = try? value.decode(Double.self) {
            text = String(double)
        } else {
            text = nil
        }
    }
}
