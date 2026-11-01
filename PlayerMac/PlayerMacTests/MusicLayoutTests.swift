import AppKit
import SwiftUI
import Testing

@testable import Kinrox

/// Opt-in render artifacts for comparing both approved window sizes with Figma.
@MainActor
struct MusicLayoutTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_MUSIC_SNAPSHOTS"] != nil))
    func renderApprovedSizes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["KINROX_MUSIC_SNAPSHOTS"] else {
            return
        }
        let session = PlayerSession(recents: RecentFilesStore(), demoMusic: true)
        session.mode = .music
        for size in [NSSize(width: 1440, height: 900), NSSize(width: 1024, height: 768)] {
            for source in ["albums", "liked", "queue"] {
                if source == "liked" {
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
