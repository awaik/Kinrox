import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Kinrox

@Suite("Player state", .timeLimit(.minutes(1)))
@MainActor
struct PlayerViewModelTests {
    @Test("Pause, interaction, and pointer exit restore cursor without motion")
    func overlayRestoresCursor() async throws {
        var hidden = false
        var overlay: OverlayController? = OverlayController { hidden = $0 }
        overlay?.canHide = true
        overlay?.activity()
        try await Task.sleep(for: OverlayController.idleDelay + .milliseconds(200))
        #expect(hidden && overlay?.isVisible == false)
        overlay?.canHide = false
        #expect(!hidden && overlay?.isVisible == true)
        hidden = true
        overlay?.pointerLeft()
        #expect(!hidden)
        hidden = true
        overlay?.set(.popover, active: true)
        #expect(!hidden)
        hidden = true
        overlay = nil
        #expect(!hidden)
    }

    @Test("UI does not reject pairing by wall clock: timeout controlled by transport")
    func expiredPairingOnAppearance() async throws {
        var declined = false
        let prompt = PairingPrompt(
            deviceName: "iPhone", code: "123456", expiresAt: Date().addingTimeInterval(-10))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: PairingCodeView(prompt: prompt) { declined = true })
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!declined)
        #expect(prompt.remaining(at: Date()) == 0)
    }

    @Test("Open sends URL; playback state confirmed by engine")
    func openWaitsForEngine() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        let url = URL(fileURLWithPath: "/tmp/Movie with spaces.mkv")
        model.open(url: url)
        #expect(engine.openedURLs == [url])
        #expect(model.isLoading)
        #expect(!model.hasMedia)
        engine.continuation.yield(.started)
        engine.continuation.yield(.property(.title, .text("Movie")))
        engine.continuation.yield(.loaded)
        for _ in 0..<100 where !model.hasMedia { await Task.yield() }
        #expect(model.hasMedia)
        #expect(!model.isLoading)
        #expect(model.title == "Movie")
        await model.shutdown()
    }

    @Test("Changing file resets old duration, position, and decoder")
    func replacementResetsState() async {
        let model = PlayerViewModel(engine: FakePlayerEngine())
        model.receive(.loaded)
        model.receive(.property(.duration, .number(120)))
        model.receive(.property(.position, .number(32)))
        model.receive(.property(.hardwareDecoder, .text("videotoolbox")))
        model.receive(.started)
        #expect(model.position == 0)
        #expect(model.duration == 0)
        #expect(model.hardwareDecoder.isEmpty)
        #expect(model.isLoading && !model.hasMedia)
        await model.shutdown()
    }

    @Test("Open and decode errors are visible to user")
    func errorsAreVisible() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        engine.loadError = MPVError("File unavailable")
        model.open(url: URL(fileURLWithPath: "/missing.mkv"))
        #expect(model.errorMessage == "File unavailable")
        #expect(!model.isLoading)
        engine.loadError = nil
        model.open(url: URL(fileURLWithPath: "/broken.mkv"))
        #expect(model.errorMessage == nil)
        model.receive(.ended(error: "Corrupted file"))
        #expect(model.errorMessage == "Corrupted file")
        #expect(!model.hasMedia && !model.isLoading)
        await model.shutdown()
    }

    @Test(
        "Pause and EOF publish last position without waiting for next tick",
        arguments: [PlaybackProperty.paused, .endReached])
    func finalPosition(_ property: PlaybackProperty) async {
        let model = PlayerViewModel(engine: FakePlayerEngine())
        model.receive(.property(.position, .number(1)))
        model.receive(.property(.position, .number(1.05)))
        #expect(model.position == 1)
        model.receive(.property(property, .flag(true)))
        #expect(model.position == 1.05)
        model.receive(.property(.position, .number(1.06)))
        #expect(model.position == 1.06)
        await model.shutdown()
    }

    @Test(
        "Seek completion updates UI position under any order of restart and time-pos",
        arguments: [true, false])
    func positionAfterSeek(positionFirst: Bool) async {
        let model = PlayerViewModel(engine: FakePlayerEngine())
        model.receive(.loaded)
        model.receive(.property(.position, .number(1)))
        model.receive(.property(.position, .number(1.05)))
        #expect(model.position == 1)
        if positionFirst { model.receive(.property(.position, .number(1.5))) }
        model.receive(.playbackRestarted)
        if !positionFirst { model.receive(.property(.position, .number(1.5))) }
        #expect(model.position == 1.5)
        await model.shutdown()
    }

    @Test(
        "Resetting file and unavailable position do not return cached time",
        arguments: [PlaybackEvent.started, .property(.position, .unavailable)])
    func finalPositionAfterReset(_ event: PlaybackEvent) async {
        let model = PlayerViewModel(engine: FakePlayerEngine())
        model.receive(.property(.position, .number(8)))
        model.receive(.property(.position, .number(8.05)))
        model.receive(event)
        model.receive(.property(.paused, .flag(true)))
        #expect(model.position == 0)
        await model.shutdown()
    }

    @Test("Closed model ignores late events and new files")
    func shutdownRejectsEvents() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        await model.shutdown()
        model.receive(.loaded)
        model.open(url: URL(fileURLWithPath: "/late.mkv"))
        #expect(!model.hasMedia)
        #expect(engine.openedURLs.isEmpty)
        #expect(engine.shutdownCount == 1)
    }

    @Test("Unavailable and non-finite properties do not leave invalid time")
    func invalidProperties() async {
        let model = PlayerViewModel(engine: FakePlayerEngine())
        model.receive(.property(.duration, .number(12)))
        model.receive(.property(.duration, .number(.nan)))
        #expect(model.duration == 12)
        model.receive(.property(.duration, .unavailable))
        #expect(model.duration == 0)
        await model.shutdown()
    }
}
