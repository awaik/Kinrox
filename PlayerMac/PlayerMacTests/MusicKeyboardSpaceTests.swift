import AppKit
import Testing

@testable import Kinrox

@Suite("Music Space routing", .serialized)
@MainActor
struct MusicKeyboardSpaceTests {
    private class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @Test func spacePausesMusicBeforeAFocusedModeButtonCanActivate() async throws {
        let music = MusicViewModel()
        let engine = FakeMusicEngine()
        music.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        music.play(music.catalog.tracks)
        await coordinator.settle()
        let item = try #require(music.queue.current)
        music.receive(
            MusicPlaybackSnapshot(
                uri: item.track.uri, position: 12, duration: 120, paused: false,
                volume: 0, deviceName: "Fixture", occurrenceID: item.id))
        let window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MusicKeyboard.KeyboardView(model: music)
        window.contentView = view
        let button = NSButton(title: "Video", target: nil, action: nil)
        view.addSubview(button)
        window.makeFirstResponder(button)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        #expect(event.window === window)
        #expect(view.handle(event))
        await coordinator.settle()
        #expect(engine.commands.last == .pause(true))
        let count = engine.commands.count
        let repeated = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        #expect(view.handle(repeated))
        await coordinator.settle()
        #expect(engine.commands.count == count)
        let editor = NSTextView()
        view.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        #expect(!view.handle(event))
        window.makeFirstResponder(button)
        view.enabled = false
        #expect(!view.handle(event))
        await coordinator.close()
    }
}
