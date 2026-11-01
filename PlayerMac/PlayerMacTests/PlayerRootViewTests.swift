import AppKit
import Testing

@testable import Kinrox

@Suite("Player root layout", .timeLimit(.minutes(1)))
@MainActor
struct PlayerRootViewTests {
    @Test("Fullscreen removes the mode bar's space and preserves the video view on exit")
    func fullscreenVideoFillsContent() async throws {
        let controller = try PlayerWindowController { _ in }
        controller.model.setVolume(0)
        do {
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            controller.showWindow(nil)
            try await layout(content)
            let video = try #require(videoView(in: content))
            let windowedHeight = video.bounds.height
            #expect(windowedHeight < content.bounds.height)

            controller.model.isFullscreen = true
            try await layout(content)
            #expect(videoView(in: content) === video)
            #expect(abs(video.bounds.height - content.bounds.height) < 1)

            controller.model.isFullscreen = false
            try await layout(content)
            #expect(videoView(in: content) === video)
            #expect(abs(video.bounds.height - windowedHeight) < 1)
        } catch {
            controller.close()
            await controller.model.shutdown()
            throw error
        }
        controller.close()
        await controller.model.shutdown()
    }

    private func layout(_ content: NSView) async throws {
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        content.layoutSubtreeIfNeeded()
    }

    private func videoView(in view: NSView) -> VideoHostView? {
        if let video = view as? VideoHostView { return video }
        for child in view.subviews {
            if let video = videoView(in: child) { return video }
        }
        return nil
    }
}
