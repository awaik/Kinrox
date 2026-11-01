import AppKit
import Testing

@testable import Kinrox

@MainActor
struct MusicKeyboardTests {
    @Test func shortcutsWorkWithRussianLayoutAndCapsLock() throws {
        for (characters, keyCode, expected) in [
            ("а", UInt16(3), "f"), ("я", 6, "z"), ("д", 37, "l"),
            ("F", 3, "f"), ("Z", 6, "z"), ("L", 37, "l"),
        ] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            #expect(MusicKeyboard.matchesKey(event, character: expected, keyCode: keyCode))
        }
    }

    @Test func latinRemappedKeysDoNotTriggerPhysicalFallback() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: 0, context: nil, characters: "u", charactersIgnoringModifiers: "u",
                isARepeat: false, keyCode: 3))
        #expect(!MusicKeyboard.matchesKey(event, character: "f", keyCode: 3))
    }
}
