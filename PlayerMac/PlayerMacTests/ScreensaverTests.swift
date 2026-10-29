import AppKit
import RemoteProtocol
import SwiftUI
import Testing

@testable import Kinrox

@Suite("Matrix screensaver", .timeLimit(.minutes(1)))
@MainActor struct ScreensaverTests {
    @Test("Matrix keeps drawing new frames in an AppKit-hosted window without a SwiftUI scene")
    func animatedFrames() async throws {
        // Honor the host's accessibility setting rather than changing it for a test.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = NSHostingView(
            rootView: MatrixRainView()
                .environment(\.scenePhase, .background))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let first = try frame(view)
        try await Task.sleep(for: .milliseconds(400))
        let second = try frame(view)
        #expect(first != second)
    }

    private func frame(_ view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test("Start waits for mpv pause; exit retains movie position and fullscreen")
    func pauseBeforeShowing() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        model.receive(.loaded)
        model.receive(.property(.position, .number(42)))
        model.isFullscreen = true
        #expect(model.startMatrix())
        #expect(engine.commands == [.paused(true)])
        #expect(model.isStartingScreensaver)
        #expect(model.screensaver == .off)
        #expect(!model.screensaverPresentation.showsHint)
        model.receive(.property(.paused, .flag(true)))
        #expect(model.screensaver == .matrix)
        #expect(model.screensaverPresentation.showsHint)
        #expect(!model.togglePause())
        #expect(!model.setPaused(false))
        #expect(!model.seek(by: 10))
        #expect(model.stopScreensaver())
        #expect(model.paused && model.isFullscreen && model.position == 42)
        #expect(engine.commands == [.paused(true)])
        #expect(!model.screensaverPresentation.showsHint)
        await model.shutdown()
    }

    @Test("Esc during pending pause prevents a late activation")
    func cancelPendingStart() async {
        let model = PlayerViewModel(engine: FakePlayerEngine())
        model.receive(.loaded)
        model.startMatrix()
        model.stopScreensaver()
        model.receive(.property(.paused, .flag(true)))
        #expect(model.paused)
        #expect(!model.isScreensaverEngaged)
        #expect(!model.screensaverPresentation.showsHint)
        await model.shutdown()
    }

    @Test("Start works without media, and the hint disappears once after 3 seconds")
    func oneShotHint() async throws {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        #expect(model.startMatrix())
        #expect(model.screensaver == .matrix)
        #expect(engine.commands.isEmpty)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(model.screensaverPresentation.showsHint)
        model.startMatrix()  // Repeated menu commands must not restart the hint timer.
        try await Task.sleep(for: .milliseconds(1700))
        #expect(!model.screensaverPresentation.showsHint)
        #expect(model.screensaver == .matrix)
        model.stopScreensaver()
        model.startMatrix()
        #expect(model.screensaverPresentation.showsHint)
        await model.shutdown()
        #expect(!model.isScreensaverEngaged)
        #expect(!model.screensaverPresentation.showsHint)
    }

    @Test("A pause error does not replace the movie with Matrix")
    func failedPause() async {
        let engine = FakePlayerEngine()
        engine.commandError = CocoaError(.fileReadUnknown)
        let model = PlayerViewModel(engine: engine)
        model.receive(.loaded)
        #expect(!model.startMatrix())
        #expect(!model.isScreensaverEngaged)
        #expect(model.errorMessage != nil)
        await model.shutdown()
    }

    @Test("EOF cannot auto-advance while a screensaver pause is pending or active")
    func endOfFile() async throws {
        let h = try RemoteServerHarness()
        try await h.loaded()
        let opened = h.engine.openedURLs
        h.model.startMatrix()
        h.model.receive(.property(.endReached, .flag(true)))
        #expect(h.engine.openedURLs == opened)
        h.model.receive(.property(.paused, .flag(true)))
        h.model.receive(.property(.endReached, .flag(false)))
        h.model.receive(.property(.endReached, .flag(true)))
        #expect(h.engine.openedURLs == opened)
        #expect(h.server.snapshot.hasMedia)
        #expect(h.server.snapshot.screensaver == .matrix)
        await h.stop()
    }

    @Test("A paused movie starts immediately; opening another file exits the screensaver")
    func pausedMovieAndOpen() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        model.receive(.loaded)
        model.receive(.property(.paused, .flag(true)))
        model.startMatrix()
        #expect(model.screensaver == .matrix)
        #expect(engine.commands.isEmpty)
        model.open(url: URL(fileURLWithPath: "/tmp/matrix-next.mkv"))
        #expect(!model.isScreensaverEngaged)
        #expect(!model.startMatrix())  // Wait until the new file finishes loading.
        await model.shutdown()
    }
}
