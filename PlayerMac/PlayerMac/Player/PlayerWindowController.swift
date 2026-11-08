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
    var isPointerInTitlebar: () -> Bool = { false }
}

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    static let titlebarHeight: CGFloat = 52

    let model: PlayerViewModel
    let overlay = OverlayController()
    private weak var session: PlayerSession?
    private let onClose: (PlayerViewModel) -> Void
    private var desiredFullscreen: Bool?
    private var fullscreenTransition = false
    private var escapeMonitor: Any?
    private var pointerMonitor: Any?
    private var controlsVisible = true

    init(
        session: PlayerSession = PlayerSession(recents: RecentFilesStore()),
        recents: RecentFilesStore? = nil, pairing: PairingCenter? = nil,
        remote: RemoteServer? = nil, updates: UpdateCenter? = nil,
        actions: PlayerActions = PlayerActions(),
        onClose: @escaping (PlayerViewModel) -> Void
    ) throws {
        let engine = try MPVPlayer()
        model = PlayerViewModel(engine: engine, recents: recents)
        self.session = session
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Kinrox"
        // Title drawn by SwiftUI over video; system bar is transparent.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.acceptsMouseMovedEvents = true
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
            setControlsVisible: { [weak self, weak window, weak session] visible in
                self?.controlsVisible = visible
                Self.setTrafficLights(visible: visible || session?.mode == .music, in: window)
            },
            setTitle: { [weak window] title in window?.title = title.isEmpty ? "Kinrox" : title },
            isPointerInTitlebar: { [weak self, weak window] in
                guard let self, let window, window.isVisible else { return false }
                return Self.isPointerInTitlebar(in: window, isFullscreen: self.model.isFullscreen)
            })
        window.contentView = NSHostingView(
            rootView: PlayerRootView(
                session: session,
                video: PlayerView(
                    model: model, recents: recents, pairing: pairing, remote: remote,
                    updates: updates, videoLayer: engine.videoLayer, actions: actions,
                    chrome: chrome, overlay: overlay),
                modeChanged: { [weak self, weak window] mode in
                    guard let window else { return }
                    if mode != .video {
                        self?.overlay.set(.titlebar, active: false)
                        self?.model.isShowingConnectPhone = false
                    }
                    window.contentMinSize =
                        mode == .music
                        ? NSSize(width: 1024, height: 768) : NSSize(width: 640, height: 360)
                    if mode == .music {
                        let size = window.contentLayoutRect.size
                        window.setContentSize(
                            NSSize(width: max(1024, size.width), height: max(768, size.height)))
                    }
                    Self.setTrafficLights(
                        visible: mode == .music || self?.controlsVisible == true, in: window)
                }))
        window.center()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak pairing] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.window, event.keyCode == 53,
                    self.window?.attachedSheet == nil, pairing?.prompt == nil,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return false }
                return self.handleEscapeKey()
            }
            // Consume the first Esc before AppKit exits native fullscreen.
            return consumed ? nil : event
        }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible,
                    event.window === window || self.overlay.interactions.contains(.titlebar)
                else { return }
                self.handlePointerEvent()
            }
            return event
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
    }

    static func isPointerInTitlebar(
        at point: NSPoint? = nil, in window: NSWindow?, isFullscreen: Bool
    ) -> Bool {
        guard let window else { return false }
        let location = point ?? window.mouseLocationOutsideOfEventStream
        let bounds = NSRect(origin: .zero, size: window.frame.size)
        guard bounds.contains(location) else { return false }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            if let button = window.standardWindowButton(type) {
                let rect = button.convert(button.bounds, to: nil).insetBy(dx: -6, dy: -6)
                if rect.contains(location) { return true }
            }
        }
        guard !isFullscreen else { return false }
        return location.y >= bounds.maxY - titlebarHeight
    }

    @discardableResult
    func handleEscapeKey() -> Bool {
        if model.isScreensaverEngaged {
            model.stopScreensaver()
            return true
        }
        guard session?.mode == .video, session?.isOpenPanelShown != true,
            model.trackController.presentation == nil,
            !model.trackController.isChoosingFile
        else { return false }
        if model.isShowingConnectPhone {
            model.isShowingConnectPhone = false
            return true
        }
        if model.isShowingHome || model.isStartingHome, model.hasMedia {
            return model.returnToVideo()
        }
        if !model.isFullscreen, model.hasMedia {
            return model.showHome()
        }
        return false
    }

    func handlePointerEvent(at point: NSPoint? = nil) {
        guard session?.mode == .video, !model.isScreensaverEngaged else {
            overlay.set(.titlebar, active: false)
            return
        }
        let location = point ?? window?.mouseLocationOutsideOfEventStream
        if Self.isPointerInTitlebar(at: location, in: window, isFullscreen: model.isFullscreen) {
            overlay.set(.titlebar, active: true)
            overlay.activity()
        } else if overlay.interactions.contains(.titlebar) {
            overlay.set(.titlebar, active: false)
            if let window, let location,
                NSRect(origin: .zero, size: window.frame.size).contains(location)
            {
                overlay.activity()
            } else {
                overlay.pointerLeft()
            }
        }
    }

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
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        window?.contentView = nil
        onClose(model)
    }
}
