import AppKit
import Foundation
import MediaPlayer
import Testing

@testable import Kinrox

@Suite("libmpv: real playback", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MPVPlaybackTests {
    @Test("Live publication preserves pause, advances at EOF, and leaves later downloads stopped")
    func liveFolderPlayback() async throws {
        let folder = try LivePlaylistFolder()
        defer { folder.remove() }
        let source = try media("h264.mkv")
        let first = folder.url.appendingPathComponent("Episode 1.mkv")
        let second = folder.url.appendingPathComponent("Episode 2.mkv")
        let temporary = second.appendingPathExtension("part")
        try FileManager.default.copyItem(at: source, to: first)
        let player = try MPVPlayer()
        let model = PlayerViewModel(engine: player)
        let window = window(for: player)
        do {
            try player.setVolume(0)
            model.open(url: first)
            try await waitUntil { model.hasMedia && model.position > 0.3 && model.playlist != nil }
            #expect(!model.canNext)
            model.setPaused(true)
            try await waitUntil { model.paused }
            let position = model.position
            try FileManager.default.copyItem(at: source, to: temporary)
            #expect(FolderPlaylist.scan(for: first).count == 1)
            try FileManager.default.moveItem(at: temporary, to: second)
            try await waitUntil { model.canNext }
            #expect(model.currentURL == first && model.paused && model.position == position)
            #expect(model.playbackVolume == 0)
            model.seek(to: model.duration - 0.4)
            model.setPaused(false)
            try await waitUntil {
                model.currentURL?.lastPathComponent == second.lastPathComponent && !model.isLoading
            }
            try await waitUntil { model.position > 0.3 }
            model.seek(to: model.duration - 0.4)
            try await waitUntil { model.isAtEnd && model.eofTask == nil }
            try FileManager.default.copyItem(
                at: source, to: folder.url.appendingPathComponent("Episode 3.mkv"))
            try await waitUntil { model.canNext }
            #expect(
                model.currentURL?.lastPathComponent == second.lastPathComponent && model.isAtEnd)
            #expect(model.playbackVolume == 0)
        } catch {
            window.orderOut(nil)
            await model.shutdown()
            throw error
        }
        window.orderOut(nil)
        await model.shutdown()
    }

    @Test("Rapid setFullscreen calls preserve last command after native animation")
    func queuedFullscreen() async throws {
        let controller = try PlayerWindowController { _ in }
        let model = controller.model
        let window = try #require(controller.window)
        model.setVolume(0)
        var entered = false
        var exited = false
        let observer = model.observePlayback { _ in
            if model.isFullscreen { entered = true } else if entered { exited = true }
        }
        do {
            controller.showWindow(nil)
            NSApp.activate()
            for value in [true, true, false, true, false] {
                #expect(model.setFullscreen(value))
            }
            try await waitUntil(
                { entered && exited },
                message: "Last setFullscreen(false) lost during full screen transition")
            #expect(!window.styleMask.contains(.fullScreen))
            // Next command must also work: transition does not remain blocked.
            #expect(model.setFullscreen(true))
            try await waitUntil { model.isFullscreen }
            #expect(model.setFullscreen(false))
            try await waitUntil { !model.isFullscreen }
        } catch {
            model.removePlaybackObserver(observer)
            controller.close()
            await model.shutdown()
            throw error
        }
        model.removePlaybackObserver(observer)
        controller.close()
        await model.shutdown()
    }

    private func media(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("DerivedData/M1Media/\(name)")
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "First run bash Scripts/make-test-media.sh")
        return url
    }

    private func waitUntil(
        _ condition: () -> Bool,
        message: Comment = "State not reached within 10 seconds",
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), message, sourceLocation: sourceLocation)
    }

    private func window(for player: MPVPlayer) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = VideoHostView(videoLayer: player.videoLayer)
        // Fully occluded CA layer may choose not to render. Test requires visible
        // buffer, even if user works in another application/Space.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.orderFrontRegardless()
        return window
    }

    @Test(
        "MP4/H.264, MKV/H.264, and MKV/HEVC 10-bit: video, Core Audio, VideoToolbox",
        arguments: ["h264.mp4", "h264.mkv", "hevc.mkv"])
    func playsMedia(_ name: String) async throws {
        let url = try media(name)
        let player = try MPVPlayer()
        let model = PlayerViewModel(engine: player)
        let center = FakeNowPlayingCenter()
        let nowPlaying = NowPlayingController(center: center)
        nowPlaying.connect(to: model)
        let window = window(for: player)
        do {
            try await waitUntil(
                { window.occlusionState.contains(.visible) },
                message: "Render test requires unobscured window in macOS graphical session")
            try player.setVolume(0)
            model.open(url: url)
            try await waitUntil { model.hasMedia && model.position > 0.3 }
            #expect(model.duration >= 11.9)
            #expect(model.volume == 0)
            #expect(model.hardwareDecoder == "videotoolbox")
            #expect(model.audioOutput == "coreaudio")
            #expect(model.title.contains(name))
            #expect(
                center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == model.displayTitle)
            #expect(center.playbackState == .playing)
            #expect(player.videoLayer.resources.renderedFrameCount > 2)
            try player.setPaused(true)
            try await waitUntil { model.paused }
            #expect(center.playbackState == .paused)
            let scale = window.backingScaleFactor
            for size in [
                CGSize(width: 853, height: 500), CGSize(width: 720, height: 405),
                CGSize(width: 960, height: 540), CGSize(width: 640, height: 360),
            ] {
                let frames = player.videoLayer.resources.renderedFrameCount
                // External transaction must not drop redraw request during pause.
                CATransaction.begin()
                window.setContentSize(size)
                CATransaction.commit()
                try await waitUntil {
                    player.videoLayer.resources.renderedFrameCount > frames
                        && player.videoLayer.resources.renderedSize
                            == CGSize(width: size.width * scale, height: size.height * scale)
                }
            }
            // Testing buffer resize without new frame and without second monitor.
            for backingScale in [1, scale] {
                player.videoLayer.updateGeometry(
                    frame: CGRect(x: 0, y: 0, width: 640, height: 360), scale: backingScale)
                try await waitUntil {
                    player.videoLayer.resources.renderedSize
                        == CGSize(width: 640 * backingScale, height: 360 * backingScale)
                }
            }
            #expect(player.videoLayer.contentsScale == window.backingScaleFactor)
            // Hidden window does not need new buffer, but it must update upon display.
            window.orderOut(nil)
            window.setContentSize(CGSize(width: 800, height: 450))
            window.orderFrontRegardless()
            try await waitUntil {
                window.occlusionState.contains(.visible)
                    && player.videoLayer.resources.renderedSize
                        == CGSize(width: 800 * scale, height: 450 * scale)
            }
            try player.seek(absolute: 5)
            try await waitUntil { abs(model.position - 5) < 0.15 }
            try await waitUntil {
                abs(
                    (center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
                        ?? -1) - 5) < 0.15
            }
            // Loading next file must unpause previous.
            model.open(url: url)
            try await waitUntil { !model.paused && model.position < 2 && model.hasMedia }
            window.close()
            await model.shutdown()
            await player.shutdown()
            #expect(throws: MPVError.self) { try player.setPaused(false) }
        } catch {
            window.close()
            await model.shutdown()
            throw error
        }
    }

    @Test("Ten open and close window cycles during playback")
    func repeatedWindowClose() async throws {
        let url = try media("h264.mkv")
        for _ in 0..<10 {
            var closeTask: Task<Void, Never>?
            let controller = try PlayerWindowController { model in
                closeTask = Task { await model.shutdown() }
            }
            controller.showWindow(nil)
            controller.model.setVolume(0)
            controller.model.open(url: url)
            do {
                try await waitUntil { controller.model.position > 0.15 }
                controller.close()
                let task = try #require(closeTask)
                await task.value
                #expect(!controller.model.hasMedia)
            } catch {
                controller.close()
                await closeTask?.value
                throw error
            }
        }
    }

    @Test("Close immediately after loadfile and without open file")
    func closeDuringLoad() async throws {
        let url = try media("hevc.mkv")
        for index in 0..<6 {
            let player = try MPVPlayer()
            try player.setVolume(0)
            if index.isMultiple(of: 2) { try player.load(url: url) }
            await player.shutdown()
        }
    }

    @Test("Non-existent file and network URL rejected before loadfile")
    func invalidURLs() async throws {
        let player = try MPVPlayer()
        #expect(throws: (any Error).self) {
            try player.load(url: URL(fileURLWithPath: "/kinrox-missing-\(UUID()).mkv"))
        }
        #expect(throws: MPVError.self) {
            try player.load(url: URL(string: "https://example.com/movie.mp4")!)
        }
        await player.shutdown()
    }

    @Test("Decoding error and recovery; hidden window continues playback")
    func failedFileAndHiddenWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinrox-load-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var systemRecents: [URL] = []
        let recents = RecentFilesStore(fileURL: folder.appendingPathComponent("recent.json")) {
            systemRecents.append($0)
        }
        let player = try MPVPlayer()
        let model = PlayerViewModel(engine: player, recents: recents)
        let window = window(for: player)
        do {
            model.open(url: URL(fileURLWithPath: #filePath))
            try await waitUntil { model.errorMessage != nil }
            #expect(!model.hasMedia && !model.isLoading)
            #expect(model.currentURL == nil)
            #expect(recents.items.isEmpty && systemRecents.isEmpty)
            try player.setVolume(0)
            model.open(url: try media("h264.mp4"))
            try await waitUntil { model.position > 0.2 && model.hasMedia }
            #expect(recents.items.count == 1 && systemRecents.count == 1)
            window.orderOut(nil)
            let position = model.position
            try await waitUntil { model.position > position + 0.5 }
            let frames = player.videoLayer.resources.renderedFrameCount
            window.orderFront(nil)
            try await waitUntil { player.videoLayer.resources.renderedFrameCount > frames }
            window.close()
            await model.shutdown()
        } catch {
            window.close()
            await model.shutdown()
            throw error
        }
    }
}
