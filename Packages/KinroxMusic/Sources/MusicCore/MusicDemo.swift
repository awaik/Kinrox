import Foundation

/// Fictional Figma catalogue, translated to the English source language. Never Spotify IDs.
public enum MusicDemo {
    public static let artists: [MusicArtist] = [
        artist("north", "Northern Shore"), artist("lune", "Lune"), artist("amber", "Amber"),
        artist("city", "City of Dreams"), artist("cat", "Moon Cat"),
        artist("train", "Night Express"),
        artist("blue", "Blue Hour"), artist("glass", "Glass Garden"),
        artist("white", "White Nights"),
        artist("sea", "Sea Breeze"), artist("lights", "Northern Lights"),
    ]

    private static let records: [(String, String, [String], String, [(String, Double)])] = [
        ("dreams", "City of Dreams", ["city"], "2019", [("Dreams", 236), ("Windows", 204)]),
        ("neon", "Neon", ["city", "cat"], "2021", [("Neon Rain", 261), ("Night Cats", 227)]),
        ("cats", "Cat Dreams", ["cat"], "2024", [("Purring", 178), ("Moonlight", 231)]),
        ("carriage", "Last Carriage", ["train"], "2018", [("Wayside", 276), ("Night Train", 234)]),
        ("water", "Lights on the Water", ["north"], "2021", [("Harbour", 245), ("Water", 208)]),
        (
            "evening", "Quiet Evening", ["north", "lune"], "2024",
            [
                ("Evening Begins", 221), ("The Pier", 245), ("Quiet Light", 252), ("Twilight", 238),
                ("The Boat", 320), ("Slow Rain", 213), ("City Asleep", 287), ("Warm Wind", 196),
                ("After Midnight", 242), ("Stars over Water", 271), ("Night Train", 234),
                ("Quiet Evening", 368),
            ]
        ),
        ("lighthouse", "Lighthouse (EP)", ["north", "amber"], "2019", [("Lighthouse", 214)]),
        ("blue", "Blue Hour", ["blue"], "2022", [("Blue Hour", 284)]),
        ("greenhouse", "Greenhouse", ["glass"], "2023", [("Glass and Light", 248)]),
        ("white", "White Night", ["white"], "2022", [("White Night", 302)]),
        ("surf", "Surf", ["sea"], "2023", [("Wave", 209), ("Northern Wind", 218)]),
        ("north", "Northern Lights", ["lights", "amber"], "2022", [("Road North", 239)]),
    ]

    private static let demoLikedAddedAt: [String: Date] = [
        "evening-0": Date(timeIntervalSince1970: 1_792_281_600),
        "evening-2": Date(timeIntervalSince1970: 1_792_022_400),
        "evening-4": Date(timeIntervalSince1970: 1_791_590_400),
        "evening-7": Date(timeIntervalSince1970: 1_790_985_600),
        "neon-0": Date(timeIntervalSince1970: 1_790_208_000),
    ]

    private static let demoPlaylistAddedAt: [String: [String: Date]] = [
        "evening-2": ["evening": Date(timeIntervalSince1970: 1_792_108_800)],
        "neon-0": [
            "evening": Date(timeIntervalSince1970: 1_791_763_200),
            "road": Date(timeIntervalSince1970: 1_791_244_800),
        ],
        "evening-4": ["evening": Date(timeIntervalSince1970: 1_791_504_000)],
        "cats-0": ["road": Date(timeIntervalSince1970: 1_791_072_000)],
    ]

    public static let catalog: MusicCatalog = {
        var tracks: [MusicTrack] = []
        var albums: [MusicAlbum] = []
        for (id, title, artistIDs, year, titles) in records {
            let albumArtists = artistIDs.compactMap { id in artists.first { $0.id == id } }
            var ids: [String] = []
            for (index, entry) in titles.enumerated() {
                let trackID = "\(id)-\(index)"
                ids.append(trackID)
                var trackArtists = albumArtists
                if id == "evening" {
                    trackArtists = [artists[0]]
                    if index == 2 || index == 6 { trackArtists.append(artists[1]) }
                    if index == 4 { trackArtists.append(artists[2]) }
                    if index == 10 { trackArtists.append(artists[5]) }
                }
                tracks.append(
                    MusicTrack(
                        id: trackID, uri: "demo:track:\(trackID)", title: entry.0,
                        artists: trackArtists, albumID: id, albumTitle: title, duration: entry.1,
                        explicit: id == "evening" && index == 2,
                        addedAt: demoLikedAddedAt[trackID],
                        playlistAddedAt: demoPlaylistAddedAt[trackID]))
            }
            albums.append(
                MusicAlbum(
                    id: id, uri: "demo:album:\(id)", title: title, artists: albumArtists,
                    year: year, trackIDs: ids))
        }
        return MusicCatalog(tracks: tracks, albums: albums, artists: artists)
    }()

    public static var library: LibrarySnapshot {
        LibrarySnapshot(
            userID: "demo",
            likedTrackIDs: ["evening-0", "evening-2", "evening-4", "evening-7", "neon-0"],
            savedAlbumIDs: Set(catalog.albums.map(\.id)),
            followedArtistIDs: ["north", "lune", "amber"],
            playlists: [
                MusicPlaylist(
                    id: "evening", uri: "demo:playlist:evening", title: "For the Evening",
                    ownerID: "demo", trackIDs: ["evening-2", "neon-0", "evening-4"]),
                MusicPlaylist(
                    id: "road", uri: "demo:playlist:road", title: "On the Road",
                    ownerID: "friend", collaborative: true, trackIDs: ["neon-0", "cats-0"]),
                MusicPlaylist(
                    id: "focus", uri: "demo:playlist:focus", title: "Focus", ownerID: "demo"),
            ])
    }

    private static func artist(_ id: String, _ name: String) -> MusicArtist {
        MusicArtist(id: id, uri: "demo:artist:\(id)", name: name)
    }
}
