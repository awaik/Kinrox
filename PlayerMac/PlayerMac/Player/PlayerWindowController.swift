import AppKit
import SwiftUI

/// Window actions handled by AppDelegate: open dialog and general file logic.
@MainActor
struct PlayerActions {
    var openFile: () -> Void = {}
    var openRecent: (RecentItem) -> Void = { _ in }
    var open: (URL) -> Void = { _ in }
}

/// SwiftUI integration with AppKit window: window traffic lights hide with controls.
@MainActor
struct WindowChrome {
    var setControlsVisible: (Bool) -> Void = { _ in }
    var setTitle: (String) -> Void = { _ in }
}

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let model: PlayerViewModel
    private let onClose: (PlayerViewModel) -> Void
    private var desiredFullscreen: Bool?
    private var fullscreenTransition = false

    init(
        recents: RecentFilesStore? = nil, pairing: PairingCenter? = nil,
        remote: RemoteServer? = nil,
        actions: PlayerActions = PlayerActions(),
        onClose: @escaping (PlayerViewModel) -> Void
    ) throws {
        let engine = try MPVPlayer()
        model = PlayerViewModel(engine: engine, recents: recents)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Kinrox"
        // Title drawn by SwiftUI over video; system bar is transparent.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        model.onToggleFullscreen = { [weak self] in
            guard let self else { return }
            self.requestFullscreen(!(self.desiredFullscreen ?? self.model.isFullscreen))
        }
        model.onSetFullscreen = { [weak self] in self?.requestFullscreen($0) }
        let chrome = WindowChrome(
            setControlsVisible: { [weak window] visible in
                Self.setTrafficLights(visible: visible, in: window)
            },
            setTitle: { [weak window] title in window?.title = title.isEmpty ? "Kinrox" : title })
        window.contentView = NSHostingView(
            rootView: PlayerView(
                model: model, recents: recents, pairing: pairing, remote: remote,
                videoLayer: engine.videoLayer, actions: actions, chrome: chrome))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private static func setTrafficLights(visible: Bool, in window: NSWindow?) {
        guard let window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            for type in buttons {
                window.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    private func requestFullscreen(_ value: Bool) {
        desiredFullscreen = value
        applyFullscreenRequest()
    }

    private func applyFullscreenRequest() {
        guard !fullscreenTransition, let desiredFullscreen else { return }
        if desiredFullscreen == model.isFullscreen {
            self.desiredFullscreen = nil
        } else {
            fullscreenTransition = true
            window?.toggleFullScreen(nil)
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fullscreenTransition = true }
    func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true }

    func windowDidEnterFullScreen(_ notification: Notification) { finishedFullscreen(true) }

    func windowDidExitFullScreen(_ notification: Notification) { finishedFullscreen(false) }

    private func finishedFullscreen(_ value: Bool) {
        model.isFullscreen = value
        // AppKit still completing transition in didEnter/didExit and ignores
        // nested toggleFullScreen. Apply last command after callback.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.model.isClosing else { return }
            self.fullscreenTransition = false
            self.applyFullscreenRequest()
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { failedFullscreen() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { failedFullscreen() }

    private func failedFullscreen() {
        fullscreenTransition = false
        desiredFullscreen = nil
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        onClose(model)
    }
}
