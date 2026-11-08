import AppKit
import SwiftUI
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

    @Test("Hovering window traffic lights or mode bar keeps traffic lights visible and wakes them")
    func trafficLightsStayVisibleOnHoverAndWakeFromHidden() async throws {
        let controller = try PlayerWindowController { _ in }
        controller.model.setVolume(0)
        do {
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            try await layout(content)
            let close = try #require(window.standardWindowButton(.closeButton))
            let closeCenter = close.convert(
                NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
            let modeBarPoint = NSPoint(x: window.frame.width / 2, y: window.frame.height - 20)
            let videoPoint = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
            let outsidePoint = NSPoint(x: -20, y: window.frame.height + 20)

            #expect(
                PlayerWindowController.isPointerInTitlebar(
                    at: closeCenter, in: window, isFullscreen: false))
            #expect(
                PlayerWindowController.isPointerInTitlebar(
                    at: modeBarPoint, in: window, isFullscreen: false))
            #expect(
                !PlayerWindowController.isPointerInTitlebar(
                    at: videoPoint, in: window, isFullscreen: false))
            #expect(
                !PlayerWindowController.isPointerInTitlebar(
                    at: outsidePoint, in: window, isFullscreen: false))

            controller.overlay.canHide = true
            controller.handlePointerEvent(at: closeCenter)
            #expect(controller.overlay.interactions.contains(.titlebar))
            try await Task.sleep(for: .milliseconds(750))
            #expect(controller.overlay.isVisible)
            #expect(close.alphaValue == 1)

            // Leaving the window from the traffic light buttons hides after the 600ms delay.
            controller.handlePointerEvent(at: outsidePoint)
            #expect(!controller.overlay.interactions.contains(.titlebar))
            try await Task.sleep(for: .milliseconds(750))
            #expect(!controller.overlay.isVisible)

            // Moving back onto the traffic lights immediately wakes the overlay.
            controller.handlePointerEvent(at: closeCenter)
            #expect(controller.overlay.isVisible)
            #expect(controller.overlay.interactions.contains(.titlebar))
        } catch {
            controller.close()
            await controller.model.shutdown()
            throw error
        }
        controller.close()
        await controller.model.shutdown()
    }

    @Test("Escape toggles between active movie and Video Home while preserving VideoHostView")
    func escapeTogglesVideoHomeAndPreservesVideoView() async throws {
        let controller = try PlayerWindowController { _ in }
        controller.model.setVolume(0)
        do {
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            controller.showWindow(nil)
            try await layout(content)
            let video = try #require(videoView(in: content))

            // Without media, Esc is not consumed.
            #expect(!controller.handleEscapeKey())

            controller.model.open(url: URL(fileURLWithPath: "/tmp/Movie.mkv"))
            controller.model.receive(.started)
            controller.model.receive(.loaded)
            controller.model.receive(.property(.paused, .flag(true)))

            // In windowed mode with media, Esc opens Video Home and keeps VideoHostView mounted.
            #expect(controller.handleEscapeKey())
            #expect(controller.model.isShowingHome)
            try await layout(content)
            #expect(videoView(in: content) === video)

            // When Connect iPhone sheet is open on Video Home, Esc closes ConnectPhoneView first.
            controller.model.isShowingConnectPhone = true
            #expect(controller.handleEscapeKey())
            #expect(!controller.model.isShowingConnectPhone)
            #expect(controller.model.isShowingHome)

            // Pressing Esc on Video Home returns to the movie.
            #expect(controller.handleEscapeKey())
            #expect(!controller.model.isShowingHome)
            try await layout(content)
            #expect(videoView(in: content) === video)

            // In fullscreen, Esc while watching video is left to AppKit to exit fullscreen,
            // whereas Esc while viewing Video Home returns to the video first.
            controller.model.isFullscreen = true
            #expect(!controller.handleEscapeKey())
            _ = controller.model.showHome()
            #expect(controller.model.isShowingHome)
            #expect(controller.handleEscapeKey())
            #expect(!controller.model.isShowingHome)
        } catch {
            controller.close()
            await controller.model.shutdown()
            throw error
        }
        controller.close()
        await controller.model.shutdown()
    }

    @Test("Titlebar video navigation button fits left of mode picker at 640 pt minimum width")
    func titlebarVideoNavButtonFitsAtMinimumWidth() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        model.open(url: URL(fileURLWithPath: "/tmp/Movie.mkv"))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(7200)))
        model.receive(.property(.position, .number(3725)))
        model.receive(.property(.paused, .flag(true)))

        let minWindowWidth: CGFloat = 640
        let pickerMinX = (minWindowWidth - PlayerRootView.modePickerWidth) / 2
        let budget = PlayerRootView.leftNavBudget(for: minWindowWidth)
        #expect(PlayerRootView.navLeadingPadding + budget < pickerMinX)

        for showingHome in [false, true] {
            if showingHome {
                _ = model.showHome()
            } else {
                _ = model.returnToVideo()
            }
            let host = NSHostingView(
                rootView: TitlebarVideoNavButton(model: model, availableWidth: budget)
                    .preferredColorScheme(.dark))
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= budget + 0.5)
            #expect(PlayerRootView.navLeadingPadding + host.fittingSize.width < pickerMinX)
        }
        await model.shutdown()
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
