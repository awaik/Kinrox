import Foundation
import Testing

@testable import MusicCore

struct DiscoveryIdentityEquivalenceTests {
    @Test func sameIDWithDifferentMetadataUsesEachRepresentationsIdentity() {
        let fixture = MusicDiscoveryRankingTests()
        let variants = [
            fixture.track("same", title: "Song"),
            fixture.track("same", title: "Song", isrc: "USRC17607839"),
            fixture.track("same", artist: "Guest", title: "Localized title", isrc: "OTHER"),
        ]
        var index = DiscoveryIdentityIndex()
        for track in variants + variants.reversed() {
            let identity = index.identity(track)
            let expected = TrackIdentity(track)
            #expect(identity.recordingTokens == expected.recordingTokens)
            #expect(identity.primaryArtistKey == expected.primaryArtistKey)
        }
    }

    @Test func simplifiedCompilationDoesNotMaskHydratedRecordingDuringDeduplication() {
        let fixture = MusicDiscoveryRankingTests()
        let simplified = fixture.track("same", title: "Song")
        let full = fixture.track("same", title: "Song", isrc: "USRC17607839")
        let variant = fixture.track(
            "variant", artist: "Guest", title: "Other title", isrc: full.isrc)
        let album = MusicAlbum(
            id: "compilation", uri: "album", title: "Compilation", artists: [], year: "2026",
            trackIDs: [simplified.id])
        let signals: [MusicDiscoverySignal] = [
            .init(track: full, kind: .listenBrainzRecording),
            .init(track: variant, kind: .collaborator),
        ]
        let actual = MusicDiscoveryEngine.build(
            catalog: .init(), library: .init(userID: "u"),
            compilationAlbums: [(album, [simplified])], signals: signals)
        let expected = ReferenceDiscoveryEngine.build(
            catalog: .init(), library: .init(userID: "u"),
            compilationAlbums: [(album, [simplified])], signals: signals)
        #expect(actual == expected)
        #expect(actual.items.count == 1)
    }

    @Test func unicodeNormalizationPreservesReferenceBehavior() {
        for value in [
            "CHRISTIAN Löffler", "İstanbul I ı", "東京　夜", "مرحبا بالعالم", "йога ёж",
            "१२३ Ⅷ ①", "a\u{301}—b", "a\u{200D}b", "🇦🇲🙂 / ", "\tA__B  \nC",
        ] {
            #expect(
                MusicDiscoveryIdentity.normalized(value)
                    == ReferenceDiscoveryIdentity.normalized(value))
        }
    }

    @Test func tokensMatchRecordingRelationIncludingEmptyAndSwappedCredits() {
        let fixture = MusicDiscoveryRankingTests()
        let a = MusicArtist(id: "a", uri: "a", name: "Löffler")
        let b = MusicArtist(id: "b", uri: "b", name: "Dawn")
        var tracks = [
            fixture.track("same-isrc-a", title: "Night", isrc: "CODE"),
            fixture.track("same-isrc-b", title: "Different", isrc: " code "),
        ]
        for artists in [
            [a, b], [b, a], [], [.init(id: "", uri: "", name: "")],
            [.init(id: "", uri: "", name: "Other")],
        ] {
            for title in [
                "Song", "Song [2011 Remaster]", "Song (Dawn Remix)", "Song (Club Mix)", "Else",
            ] {
                tracks.append(
                    .init(
                        id: "t\(tracks.count)", uri: "t", title: title,
                        artists: artists, albumID: "a", albumTitle: "A", duration: 200))
            }
        }
        for lhs in tracks {
            for rhs in tracks {
                let intersects = !Set(TrackIdentity(lhs).recordingTokens).isDisjoint(
                    with: TrackIdentity(rhs).recordingTokens)
                #expect(intersects == ReferenceDiscoveryIdentity.sameRecording(lhs, rhs))
                #expect(
                    MusicDiscoveryIdentity.sameRecording(lhs, rhs)
                        == ReferenceDiscoveryIdentity.sameRecording(lhs, rhs))
            }
        }
    }

    @Test func sharedQualifierSuffixesPreservePrefixAndMalformedTitleBehavior() {
        let fixture = MusicDiscoveryRankingTests()
        var identities = DiscoveryIdentityIndex()
        var tracks: [MusicTrack] = []
        for prefix in ["Song", "東京", "a\u{301}", "", "Mix\nName"] {
            for suffix in [
                " (Dawn Remix)", "[2011 Remaster]", " (Club Mix)", " - Live",
                "– Live", "\u{a0}— Dawn Remix", "[x]- Live", "[x] - Live",
                " (Dawn Remix) [live] - Extended Mix", " (unfinished Remix",
                " [unfinished (Dawn Remix)", "\t- Dawn Remix\n", "(Live) more text",
                "-original (Dawn Remix)", " (with Dawn) (Dusk Edit)",
            ] {
                let track = fixture.track("t\(tracks.count)", title: prefix + suffix)
                tracks.append(track)
                #expect(
                    identities.identity(track).baseTitle
                        == ReferenceDiscoveryIdentity.baseTitle(track.title))
            }
        }
        let catalog = MusicCatalog(tracks: tracks)
        let actual = MusicDiscoveryEngine.localDiscoverySignals(
            seedIDs: [tracks[0].id], artistIDs: [], catalog: catalog, library: .init(userID: "u"))
        let expected = ReferenceDiscoveryEngine.localDiscoverySignals(
            seedIDs: [tracks[0].id], artistIDs: [], catalog: catalog, library: .init(userID: "u"))
        #expect(actual == expected)
    }

    @Test func bridgeVariantMergesMultipleSlotsAndKeepsEarliestWinner() {
        let fixture = MusicDiscoveryRankingTests()
        let tracks = [
            fixture.track("a", artist: "A", title: "Night", isrc: "ONE"),
            fixture.track("b", artist: "B", title: "Day", isrc: "TWO"),
            fixture.track("c", artist: "B", title: "Day (Dawn Remix)", isrc: "ONE"),
        ]
        let signals: [MusicDiscoverySignal] = [
            .init(track: tracks[0], kind: .listenBrainzRecording),
            .init(track: tracks[1], kind: .collaborator),
            .init(track: tracks[2], kind: .remixer),
        ]
        let actual = MusicDiscoveryEngine.build(
            catalog: .init(), library: .init(userID: "u"), signals: signals)
        let expected = ReferenceDiscoveryEngine.build(
            catalog: .init(), library: .init(userID: "u"), signals: signals)
        #expect(actual == expected)
        #expect(actual.items.count == 1)
        #expect(actual.items.first?.id == "a")
        #expect(actual.items.first?.reasons.count == 3)
    }
}
