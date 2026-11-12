import AppKit
import SwiftUI
import Testing

@testable import Kinrox

/// Opt-in render artifacts for comparing both approved window sizes with Figma.
@MainActor
struct MusicLayoutTests {
    @Test func queueButtonsHaveAccessibleLabelsWithoutHover() async throws {
        // Ask the test host to materialize SwiftUI's accessibility tree, as an AX client does.
        let read = NSSelectorFromString("accessibilityAttributeValue:")
        let write = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let attribute = "AXEnhancedUserInterface"
        let previous = NSApp.perform(read, with: attribute)?.takeUnretainedValue()
        NSApp.perform(write, with: true, with: attribute)
        defer { NSApp.perform(write, with: previous, with: attribute) }
        let music = MusicViewModel()
        let host = NSHostingView(rootView: SourceColumn(model: music))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 900), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func labels(_ element: NSObject) -> [String] {
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            let label =
                element.responds(to: labelSelector)
                ? element.perform(labelSelector)?.takeUnretainedValue() as? String : nil
            let children =
                element.responds(to: childrenSelector)
                ? element.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] : nil
            return (label.map { [$0] } ?? []) + (children ?? []).flatMap { labels($0) }
        }
        #expect(labels(host).contains(L10n.text("Add to queue")))
    }

    @Test func adjacentRowExitPreservesCurrentHover() {
        var state = MusicRowHoverState()
        state.update("album:a", hovering: true)
        state.update("playlist:b", hovering: true)
        state.update("album:a", hovering: false)
        #expect(state.id == "playlist:b")
        state.update("playlist:b", hovering: false)
        #expect(state.id == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_MUSIC_SNAPSHOTS"] != nil))
    func renderApprovedSizes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["KINROX_MUSIC_SNAPSHOTS"] else {
            return
        }
        let session = PlayerSession(recents: RecentFilesStore(), demoMusic: true)
        session.mode = .music
        session.music.setWorkspaceActive(true)
        for size in [NSSize(width: 1440, height: 900), NSSize(width: 1024, height: 768)] {
            for source in ["albums", "liked", "queue", "similar"] {
                if source == "similar" {
                    session.music.select(.similar)
                } else if source == "liked" {
                    session.music.select(.liked)
                } else if source == "queue" {
                    session.music.select(.queue)
                } else {
                    session.music.select(.albums)
                }
                let host = NSHostingView(
                    rootView: MusicView(session: session, model: session.music))
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "music-\(source)-\(Int(size.width)).png"))
            }
        }
    }
}
