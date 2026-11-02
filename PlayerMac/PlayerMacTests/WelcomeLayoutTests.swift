import AppKit
import SwiftUI
import Testing

@testable import Kinrox

@Suite("Welcome layout", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WelcomeLayoutTests {
    @Test(
        "Welcome content stays inside the window when recents and window sizes change",
        arguments: [0, 1, 4, 20])
    func recentFilesDoNotDisplaceWelcome(itemCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinrox-welcome-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("recent.json")
        let items = (0..<itemCount).map { index in
            RecentItem(
                id: UUID(),
                title: "A long series name - Season 01 Episode \(index) - 2160p WEB-DL.mkv",
                path: directory.appendingPathComponent("Episode \(index).mkv").path,
                openedAt: Date(), duration: 1800, bookmark: nil)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: fileURL)
        let recents = RecentFilesStore(fileURL: fileURL)
        let host = NSHostingView(
            rootView: WelcomeView(recents: recents, actions: PlayerActions())
                .preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        // Exercise shrinking and growing the same hosted screen, including the minimum width.
        for width: CGFloat in [1120, 640, 1440, 1120] {
            window.setContentSize(NSSize(width: width, height: 630))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()

            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
            #expect(abs(host.bounds.width - width) < 1)
            // This is a vertical scroll view: neither its viewport nor its content may overflow
            // horizontally, otherwise the centered hero and trailing actions become unreachable.
            #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
            #expect(abs(viewport.minX - host.bounds.minX) < 1)
            #expect(abs(viewport.maxX - host.bounds.maxX) < 1)

            if let directory = ProcessInfo.processInfo.environment["KINROX_WELCOME_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "welcome-\(itemCount)-\(Int(width)).png"))
            }
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { scrollView(in: $0) }.first
    }

}
