import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

struct SpotifyMetadataTests {
    @Test(arguments: [
        #"{"disallows":{"seeking":true,"pausing":false,"future_action":true}}"#,
        #"{"seeking":true,"pausing":false,"future_action":true}"#,
    ])
    func restrictionsKeepTrueFlagsAndSupportBothResponseShapes(json: String) throws {
        let actions = try JSONDecoder().decode(SpotifyActions.self, from: Data(json.utf8))
        #expect(actions.disallowed == ["seeking", "future_action"])
    }

    @Test func explicitAndUnplayableMetadataSurviveMapping() throws {
        let json =
            #"{"id":"track","uri":"spotify:track:track","name":"Full title","duration_ms":120000,"explicit":true,"is_playable":false,"album":{"id":"album","uri":"spotify:album:album","name":"Full album","artists":[]}}"#
        let track = try JSONDecoder().decode(SpotifyTrack.self, from: Data(json.utf8))
        let model = try #require(track.model())
        #expect(model.explicit == true)
        #expect(model.isPlayable == false)
        #expect(model.albumID == "album")
        #expect(model.title == "Full title")
    }

    @Test func oldMusicTrackMetadataStillDecodes() throws {
        let json =
            #"{"id":"track","uri":"spotify:track:track","title":"Title","artists":[],"albumID":"album","albumTitle":"Album","duration":100}"#
        let track = try JSONDecoder().decode(MusicTrack.self, from: Data(json.utf8))
        #expect(track.explicit == nil && track.isPlayable == nil && track.addedAt == nil)
    }

    @Test func savedAndPlaylistAddedTimestampsDecodeAndIgnoreEpochZero() throws {
        let savedJSON =
            #"{"added_at":"2026-10-18T14:22:10Z","track":{"id":"track1","uri":"spotify:track:track1","name":"Saved","duration_ms":100000,"album":{"id":"album","uri":"spotify:album:album","name":"Album","artists":[]}}}"#
        let saved = try JSONDecoder().decode(SpotifySavedTrack.self, from: Data(savedJSON.utf8))
        let savedTrack = try #require(saved.track?.model(addedAt: saved.addedDate))
        #expect(savedTrack.addedAt == Date(timeIntervalSince1970: 1_792_333_330))

        let itemJSON =
            #"{"added_at":"1970-01-01T00:00:00Z","item":{"id":"track2","uri":"spotify:track:track2","name":"Item","duration_ms":100000,"album":{"id":"album","uri":"spotify:album:album","name":"Album","artists":[]}}}"#
        let item = try JSONDecoder().decode(SpotifyPlaylistItem.self, from: Data(itemJSON.utf8))
        #expect(item.addedDate == nil)
    }
}
