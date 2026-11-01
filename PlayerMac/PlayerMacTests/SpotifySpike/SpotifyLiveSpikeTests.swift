import Foundation
import Testing

/// Explicitly opt-in live feasibility check; ordinary tests make no Spotify requests.
@Suite("Spotify Phase 0", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SpotifyLiveSpikeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SPOTIFY_CLIENT_ID"] != nil))
    func accountAndLibrary() async throws {
        guard let clientID = ProcessInfo.processInfo.environment["KINROX_SPOTIFY_CLIENT_ID"] else {
            return
        }
        let token = try await SpotifySpikeOAuth.authorize(clientID: clientID)
        let api = SpotifySpikeAPI(token: token)
        defer { api.close() }
        let profile = try await api.object("me")
        guard let userID = profile["id"] as? String else {
            throw SpotifySpikeFailure.invalidResponse
        }
        let quick =
            ProcessInfo.processInfo.environment["KINROX_SPOTIFY_SPIKE_WRITES"] == "1"
            || ProcessInfo.processInfo.environment["KINROX_SPOTIFY_SPIKE_PLAYBACK"] == "1"
        let tracks = try await api.pages("me/tracks?limit=50", firstPageOnly: quick)
        let albums = try await api.pages("me/albums?limit=50", firstPageOnly: quick)
        let artists = try await api.pages(
            "me/following?type=artist&limit=50", nested: "artists", firstPageOnly: quick)
        let playlists = try await api.pages("me/playlists?limit=50")
        _ = try await api.object("search?q=ambient&type=track,album,artist&limit=10")
        var editableCount = 0
        var memberships = 0
        let start = ContinuousClock.now
        for playlist in quick ? [] : playlists {
            let owner = playlist["owner"] as? [String: Any]
            guard owner?["id"] as? String == userID || playlist["collaborative"] as? Bool == true,
                let id = playlist["id"] as? String
            else { continue }
            editableCount += 1
            let items = try await api.pages("playlists/\(id)/items?limit=50")
            memberships += items.count
        }
        print(
            "SPOTIFY_SPIKE reads: tracks=\(tracks.count), albums=\(albums.count), artists=\(artists.count), editablePlaylists=\(editableCount), items=\(memberships), indexDuration=\(start.duration(to: .now))"
        )
        _ = try await api.object("me/player/devices")
        if ProcessInfo.processInfo.environment["KINROX_SPOTIFY_SPIKE_WRITES"] == "1" {
            try await checkWrites(api: api, tracks: tracks, albums: albums, artists: artists)
        }
        if ProcessInfo.processInfo.environment["KINROX_SPOTIFY_SPIKE_PLAYBACK"] == "1" {
            try await checkPlayback(api: api, albums: albums, tracks: tracks)
        }
        print("SPOTIFY_SPIKE completed; requests=\(api.requestCount)")
    }

    /// Exercise consolidated endpoints using already-saved items; restore each immediately.
    private func checkWrites(
        api: SpotifySpikeAPI, tracks: [[String: Any]], albums: [[String: Any]],
        artists: [[String: Any]]
    ) async throws {
        let track = tracks.first?["track"] as? [String: Any]
        let album = albums.first?["album"] as? [String: Any]
        let uris = [
            track?["uri"] as? String, album?["uri"] as? String, artists.first?["uri"] as? String,
        ].compactMap { $0 }
        for uri in uris {
            let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            // Verify restoration support before temporarily removing an existing saved item.
            _ = try await api.request("me/library?uris=\(encoded)", method: "PUT")
            _ = try await api.request("me/library?uris=\(encoded)", method: "DELETE")
            do {
                _ = try await api.request("me/library?uris=\(encoded)", method: "PUT")
            } catch {
                _ = try await api.request("me/library?uris=\(encoded)", method: "PUT")
                throw error
            }
            print("SPOTIFY_SPIKE restored library type=\(uri.split(separator: ":")[1])")
        }
        guard let uri = track?["uri"] as? String else { return }
        let created = try await api.object(
            "me/playlists", method: "POST",
            body: [
                "name": "Kinrox Phase 0 verification", "public": false,
                "description":
                    "Disposable test playlist created for Kinrox Music API verification.",
            ])
        guard let id = created["id"] as? String else { throw SpotifySpikeFailure.invalidResponse }
        _ = try await api.request(
            "playlists/\(id)/items", method: "POST", body: ["uris": [uri], "position": 0])
        _ = try await api.request(
            "playlists/\(id)/items", method: "DELETE", body: ["items": [["uri": uri]]])
        // Keep the empty verification playlist, so no user-owned playlist is deleted.
        print("SPOTIFY_SPIKE writes completed; empty verification playlist retained.")
    }
    private func waitForPlaying(_ api: SpotifySpikeAPI, uri: String) async throws -> [String: Any] {
        for _ in 0..<12 {
            try await Task.sleep(for: .seconds(1))
            let state = try await api.object("me/player")
            let item = state["item"] as? [String: Any]
            let linked = item?["linked_from"] as? [String: Any]
            if state["is_playing"] as? Bool == true,
                item?["uri"] as? String == uri || linked?["uri"] as? String == uri
            {
                return state
            }
        }
        throw SpotifySpikeFailure.timeout
    }

    private func checkPlayback(
        api: SpotifySpikeAPI, albums: [[String: Any]], tracks: [[String: Any]]
    ) async throws {
        let devices = try await api.object("me/player/devices")["devices"] as? [[String: Any]] ?? []
        for device in devices {
            print(
                "SPOTIFY_SPIKE device: name=\(device["name"] ?? ""), type=\(device["type"] ?? ""), active=\(device["isActive"] ?? false), restricted=\(device["isRestricted"] ?? true)"
            )
        }
        let initial = try await api.object("me/player")
        guard
            let device = devices.first(where: {
                $0["is_active"] as? Bool == true && $0["type"] as? String == "Computer"
            }),
            let id = device["id"] as? String,
            let track = initial["item"] as? [String: Any],
            let album = track["album"] as? [String: Any],
            let albumID = album["id"] as? String, let albumURI = album["uri"] as? String
        else { throw SpotifySpikeFailure.invalidResponse }
        let items = try await api.pages("albums/\(albumID)/tracks?limit=50")
        let uris = items.compactMap { $0["uri"] as? String }
        guard let first = uris.first else { throw SpotifySpikeFailure.invalidResponse }
        let target = "device_id=\(id)"
        _ = try await api.request("me/player/volume?volume_percent=0&\(target)", method: "PUT")
        _ = try await api.request("me/player/shuffle?state=false&\(target)", method: "PUT")
        _ = try await api.request("me/player/repeat?state=off&\(target)", method: "PUT")
        let playlists = try await api.pages("me/playlists?limit=50")
        guard
            let verification = playlists.first(where: {
                $0["name"] as? String == "Kinrox Phase 0 verification"
            }),
            let playlistID = verification["id"] as? String,
            let playlistURI = verification["uri"] as? String
        else { throw SpotifySpikeFailure.invalidResponse }
        do {
            _ = try await api.request(
                "me/player/play?\(target)", method: "PUT",
                body: [
                    "context_uri": albumURI, "offset": ["position": 0], "position_ms": 0,
                ])
            _ = try await waitForPlaying(api, uri: first)
            print("SPOTIFY_SPIKE confirmed album track 1.")
            _ = try await api.request("me/player/seek?position_ms=10000&\(target)", method: "PUT")
            try await Task.sleep(for: .seconds(1))
            let sought = try await api.object("me/player")
            #expect((sought["progress_ms"] as? Int ?? 0) >= 10000)
            _ = try await api.request("me/player/pause?\(target)", method: "PUT")
            try await Task.sleep(for: .seconds(1))
            #expect(try await api.object("me/player")["is_playing"] as? Bool == false)
            let playbackURIs = Array(
                (uris + tracks.compactMap { ($0["track"] as? [String: Any])?["uri"] as? String })
                    .prefix(3))
            _ = try await api.request(
                "playlists/\(playlistID)/items", method: "PUT", body: ["uris": playbackURIs])
            _ = try await api.request(
                "me/player/play?\(target)", method: "PUT",
                body: [
                    "context_uri": playlistURI, "offset": ["position": 0], "position_ms": 0,
                ])
            _ = try await waitForPlaying(api, uri: playbackURIs[0])
            _ = try await api.request("me/player/next?\(target)", method: "POST")
            let state = try await waitForPlaying(api, uri: playbackURIs[1])
            #expect((state["device"] as? [String: Any])?["volume_percent"] as? Int == 0)
            _ = try await api.request("me/player/pause?\(target)", method: "PUT")
            _ = try await api.request(
                "playlists/\(playlistID)/items", method: "PUT", body: ["uris": [String]()])
            print(
                "SPOTIFY_SPIKE playlist-context playback completed; muted and paused, test playlist empty."
            )
        } catch {
            _ = try? await api.request("me/player/pause?\(target)", method: "PUT")
            _ = try? await api.request(
                "playlists/\(playlistID)/items", method: "PUT", body: ["uris": [String]()])
            throw error
        }
    }

}

@MainActor
final class SpotifySpikeAPI {
    private let token: String
    private let session: URLSession
    private(set) var requestCount = 0
    init(token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.token = token
        self.session = session
    }
    func close() { session.invalidateAndCancel() }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws
        -> Data
    {
        let url: URL?
        if path.hasPrefix("https://") {
            url = URL(string: path)
        } else {
            url = URL(string: "https://api.spotify.com/v1/" + path)
        }
        guard let url, url.scheme == "https", url.host == "api.spotify.com",
            url.path.hasPrefix("/v1/")
        else {
            throw SpotifySpikeFailure.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        requestCount += 1
        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifySpikeFailure.invalidResponse
        }
        print(
            "SPOTIFY_SPIKE \(method) \(url.path) status=\(http.statusCode) duration=\(start.duration(to: .now))"
        )
        guard (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let details = payload?["error"] as? [String: Any] {
                print(
                    "SPOTIFY_SPIKE error reason=\(details["reason"] ?? ""), message=\(details["message"] ?? "")"
                )
            }
            throw SpotifySpikeFailure.http(
                status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                quotaExceeded: String(data: data, encoding: .utf8)?.contains("QUOTA_EXCEEDED")
                    == true)
        }
        return data
    }

    func object(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws
        -> [String: Any]
    {
        let data = try await request(path, method: method, body: body)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifySpikeFailure.invalidResponse
        }
        return object
    }

    func pages(_ path: String, nested: String? = nil, firstPageOnly: Bool = false) async throws
        -> [[String: Any]]
    {
        var next: String? = path
        var visited = Set<String>()
        var result: [[String: Any]] = []
        while let path = next {
            guard visited.insert(path).inserted, visited.count <= 1000 else {
                throw SpotifySpikeFailure.invalidResponse
            }
            let root = try await object(path)
            let page = nested.flatMap { root[$0] as? [String: Any] } ?? root
            guard let items = page["items"] as? [[String: Any]] else {
                throw SpotifySpikeFailure.invalidResponse
            }
            result += items
            next = firstPageOnly ? nil : page["next"] as? String
        }
        return result
    }
}
