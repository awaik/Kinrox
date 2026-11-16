import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Kinrox

/// In-memory registry; tests never change the Mac's real default apps.
@MainActor
private final class FakeRegistry: DefaultAppRegistry {
    var handlers: [String: URL] = [:]
    var requests: [String] = []
    var failure: (any Error)?
    var applyBeforeFailure = false

    func defaultApplication(for type: UTType) -> URL? { handlers[type.identifier] }

    func setDefaultApplication(_ application: URL, for type: UTType) async throws {
        requests.append(type.identifier)
        if let failure {
            if applyBeforeFailure { handlers[type.identifier] = application }
            throw failure
        }
        handlers[type.identifier] = application
    }
}

@Suite("Default video player")
@MainActor
struct DefaultVideoPlayerTests {
    private let kinrox = Bundle.main.bundleURL
    private let other = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
    private let formats = [
        DefaultVideoPlayer.Format(label: "MOV", type: .quickTimeMovie),
        DefaultVideoPlayer.Format(label: "MP4", type: .mpeg4Movie),
        DefaultVideoPlayer.Format(label: "AVI", type: .avi),
    ]

    private func makePlayer(_ registry: FakeRegistry) -> DefaultVideoPlayer {
        DefaultVideoPlayer(
            registry: registry, application: kinrox,
            bundleIdentifier: Bundle.main.bundleIdentifier, formats: formats)
    }

    @Test("Covers the v1 document types with stable labels")
    func formatList() {
        #expect(
            DefaultVideoPlayer.formats.map(\.label) == [
                "MOV", "MP4", "M4V", "MKV", "WebM", "AVI", "TS",
            ])
        #expect(DefaultVideoPlayer.formats.allSatisfy { $0.type.conforms(to: .movie) })
    }

    @Test(
        "Imported video formats remain stable when extension lookup is missing or dynamic",
        arguments: [false, true])
    func importedFormats(dynamic: Bool) throws {
        let unresolved = try #require(
            UTType(filenameExtension: "kinrox-unregistered-test-video", conformingTo: .movie))
        #expect(unresolved.isDynamic)
        let formats = DefaultVideoPlayer.makeFormats { fileExtension in
            if ["mkv", "webm"].contains(fileExtension) { return dynamic ? unresolved : nil }
            return UTType(filenameExtension: fileExtension, conformingTo: .movie)
        }
        #expect(formats.count == 7)
        #expect(formats.first { $0.label == "MKV" }?.type.identifier == "org.matroska.mkv")
        #expect(formats.first { $0.label == "WebM" }?.type.identifier == "org.webmproject.webm")
        #expect(formats.allSatisfy { !$0.type.isDynamic && $0.type.conforms(to: .movie) })
    }

    @Test("A declared extension lookup remains authoritative")
    func declaredFormat() {
        let formats = DefaultVideoPlayer.makeFormats { _ in .mpeg4Movie }
        #expect(formats.allSatisfy { $0.type == .mpeg4Movie })
    }

    @Test("Reports only formats that open elsewhere, comparing bundle identity")
    func partialStatus() {
        let registry = FakeRegistry()
        registry.handlers = [
            UTType.quickTimeMovie.identifier: other,
            UTType.mpeg4Movie.identifier: kinrox,
        ]
        let player = makePlayer(registry)
        #expect(player.otherFormats == ["MOV", "AVI"])
        #expect(!player.isDefault)
    }

    @Test("Changes only pending formats and becomes default")
    func makeDefault() async {
        let registry = FakeRegistry()
        registry.handlers = [UTType.mpeg4Movie.identifier: kinrox]
        let player = makePlayer(registry)
        await player.makeDefault()
        #expect(registry.requests == [UTType.quickTimeMovie.identifier, UTType.avi.identifier])
        #expect(player.isDefault)
        #expect(!player.failed)
        #expect(!player.isChanging)
    }

    @Test("A cancelled system confirmation stops further requests without an error")
    func cancellation() async {
        let registry = FakeRegistry()
        registry.failure = NSError(
            domain: NSCocoaErrorDomain, code: 256,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSOSStatusErrorDomain, code: Int(userCanceledErr))
            ])
        let player = makePlayer(registry)
        await player.makeDefault()
        #expect(registry.requests.count == 1)
        #expect(!player.failed)
        #expect(player.otherFormats == ["MOV", "MP4", "AVI"])
    }

    @Test("Other errors are reported and the status refreshes")
    func failure() async {
        let registry = FakeRegistry()
        registry.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        let player = makePlayer(registry)
        await player.makeDefault()
        #expect(player.failed)
        #expect(!player.isDefault)
    }

    @Test("Refreshing clears a previous error only after all handlers become Kinrox")
    func externalRecovery() async {
        let registry = FakeRegistry()
        registry.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        let player = makePlayer(registry)
        await player.makeDefault()
        #expect(player.failed)

        registry.handlers[formats[0].type.identifier] = kinrox
        player.refresh()
        #expect(player.failed)
        #expect(!player.isDefault)

        for format in formats { registry.handlers[format.type.identifier] = kinrox }
        player.refresh()
        #expect(player.isDefault)
        #expect(!player.failed)
        #expect(registry.requests.count == 1)
    }

    @Test("An error returned after the last handler changes does not override observed success")
    func appliedDespiteError() async {
        let registry = FakeRegistry()
        for format in formats.dropLast() { registry.handlers[format.type.identifier] = kinrox }
        registry.applyBeforeFailure = true
        registry.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        let player = makePlayer(registry)
        await player.makeDefault()
        #expect(registry.requests == [UTType.avi.identifier])
        #expect(player.isDefault)
        #expect(!player.failed)
        #expect(!player.isChanging)
    }
}
