import Foundation

public struct MetaBrainzAlbum: Codable, Sendable {
    public let releaseGroupMBID: String
    public let rating: Double?
    public let genres: [String]
    public let year: String?
    public let coverArtURL: URL?
}

extension MetaBrainzClient {
    public func resolveAlbum(album: String, artist: String, refresh: Bool = false) async throws
        -> MetaBrainzAlbum?
    {
        let album = album.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let artist = artist.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let albumKey = Self.normalized(album)
        let artistKey = Self.normalized(artist)
        guard !albumKey.isEmpty, !artistKey.isEmpty else { return nil }
        let key = "release-group|\(albumKey)|\(artistKey)"
        if !refresh, let cached: MetaBrainzAlbum = try await cached(key) { return cached }
        let search: ReleaseGroupSearch? = try await read(
            host: "musicbrainz.org", path: "/ws/2/release-group/",
            query: [
                "query":
                    "releasegroup:\(Self.lucenePhrase(album)) AND artist:\(Self.lucenePhrase(artist))",
                "fmt": "json", "limit": "3",
            ])
        guard
            let match = search?.groups.first(where: {
                Self.normalized($0.title) == albumKey
                    && ($0.credits.contains { Self.normalized($0.name) == artistKey }
                        || Self.normalized($0.credits.map(\.name).joined(separator: " "))
                            == artistKey)
            }), UUID(uuidString: match.id) != nil
        else { return nil }
        let details: ReleaseGroupDetails? = try await read(
            host: "musicbrainz.org", path: "/ws/2/release-group/" + match.id,
            query: ["inc": "ratings+genres", "fmt": "json"])
        let art: CoverArtResponse? = try await read(
            host: "coverartarchive.org", path: "/release-group/" + match.id, query: [:])
        try Task.checkCancellation()
        let image = art?.images.first(where: { $0.front == true }) ?? art?.images.first
        let rawYear = match.date.map { String($0.prefix(4)) }
        let result = MetaBrainzAlbum(
            releaseGroupMBID: match.id,
            rating: details?.rating?.value.flatMap { (0...5).contains($0) ? $0 : nil },
            genres: details?.genres?.map(\.name) ?? [],
            year: rawYear.flatMap { Int($0) == nil ? nil : $0 },
            coverArtURL: Self.secureCoverURL(
                image?.thumbnails["large"] ?? image?.thumbnails["small"]))
        try await save(key, value: result, ttl: 7 * 86400)
        return result
    }

    static func lucenePhrase(_ text: String) -> String {
        "\""
            + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func secureCoverURL(_ raw: String?) -> URL? {
        guard let raw, var parts = URLComponents(string: raw),
            parts.scheme == "http" || parts.scheme == "https",
            parts.user == nil, parts.password == nil, parts.port == nil,
            let host = parts.host?.lowercased(),
            host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org")
        else { return nil }
        parts.scheme = "https"
        return parts.url
    }
}

private struct ReleaseGroupSearch: Decodable {
    struct Group: Decodable {
        struct Credit: Decodable { let name: String }
        let id: String
        let title: String
        let date: String?
        let credits: [Credit]
        enum CodingKeys: String, CodingKey {
            case id, title
            case date = "first-release-date"
            case credits = "artist-credit"
        }
    }
    let groups: [Group]
    enum CodingKeys: String, CodingKey { case groups = "release-groups" }
}

private struct ReleaseGroupDetails: Decodable {
    struct Rating: Decodable { let value: Double? }
    struct Genre: Decodable { let name: String }
    let rating: Rating?
    let genres: [Genre]?
}

private struct CoverArtResponse: Decodable {
    struct Image: Decodable {
        let front: Bool?
        let thumbnails: [String: String]
    }
    let images: [Image]
}
