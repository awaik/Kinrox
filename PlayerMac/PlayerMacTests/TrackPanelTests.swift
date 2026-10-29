import AppKit
import Testing

@testable import Kinrox

@Suite("Track file panel lifecycle")
@MainActor
struct TrackPanelTests {
    private func makeController() throws -> TrackController {
        let defaults = try #require(UserDefaults(suiteName: "kinrox-panel-tests-\(UUID())"))
        let controller = TrackController(
            engine: FakePlayerEngine(), preferences: TrackPreferences(defaults: defaults),
            scanner: { _, _, _ in AsyncStream { $0.finish() } })
        let video = URL(fileURLWithPath: "/Series/01.mkv")
        controller.prepare(for: video)
        controller.loaded(path: video.path, tracks: [])
        return controller
    }

    @Test("Stop, new video and close cancel panels and ignore late replies", arguments: 0...2)
    func cancelsObsoletePanel(_ action: Int) throws {
        let controller = try makeController()
        let window = PanelTestWindow()
        let panel = DelayedTrackPanel()
        var selections = 0
        controller.presentFilePanel(panel, for: window) { _ in selections += 1 }
        #expect(controller.isChoosingFile)
        #expect(panel.began)
        let duplicate = DelayedTrackPanel()
        controller.presentFilePanel(duplicate, for: window) { _ in selections += 1 }
        #expect(!duplicate.began)
        switch action {
        case 0: controller.stop()
        case 1: controller.prepare(for: URL(fileURLWithPath: "/Series/02.mkv"))
        default: controller.close()
        }
        #expect(panel.cancelCount == 1)
        #expect(!controller.isChoosingFile)
        let next = URL(fileURLWithPath: "/Series/03.mkv")
        controller.prepare(for: next)
        controller.loaded(path: next.path, tracks: [])
        let replacement = DelayedTrackPanel()
        controller.presentFilePanel(replacement, for: window) { _ in selections += 1 }
        panel.completion?(.OK)
        #expect(selections == 0)
        #expect(controller.filePanel === replacement)
        replacement.completion?(.OK)
        #expect(selections == 1)
        #expect(!controller.isChoosingFile)
        controller.close()
    }

    @Test("A track chooser cannot overlap an existing sheet or use a sheet as its parent")
    func rejectsOverlappingSheet() throws {
        let controller = try makeController()
        let window = PanelTestWindow()
        let panel = DelayedTrackPanel()
        window.existingSheet = NSWindow()
        controller.presentFilePanel(panel, for: window) { _ in Issue.record("Unexpected selection")
        }
        #expect(!panel.began)
        #expect(!controller.isChoosingFile)
        window.existingSheet = nil
        window.parentSheet = NSWindow()
        controller.presentFilePanel(panel, for: window) { _ in Issue.record("Unexpected selection")
        }
        #expect(!panel.began)
        #expect(!controller.isChoosingFile)
        controller.close()
    }
}

@MainActor
private final class DelayedTrackPanel: NSOpenPanel {
    var began = false
    var cancelCount = 0
    var completion: ((NSApplication.ModalResponse) -> Void)?
    override var url: URL? { URL(fileURLWithPath: "/Series/01.srt") }

    override func beginSheetModal(
        for window: NSWindow,
        completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        began = true
        completion = handler
    }

    override func cancel(_ sender: Any?) { cancelCount += 1 }
}

@MainActor
private final class PanelTestWindow: NSWindow {
    var existingSheet: NSWindow?
    var parentSheet: NSWindow?
    override var attachedSheet: NSWindow? { existingSheet }
    override var sheetParent: NSWindow? { parentSheet }
}
