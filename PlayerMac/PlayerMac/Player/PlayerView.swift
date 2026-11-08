import SwiftUI

/// Root window view: video, glass control bar overlay, empty welcome screen.
struct PlayerView: View {
    @Bindable var model: PlayerViewModel
    let recents: RecentFilesStore?
    let pairing: PairingCenter?
    var remote: RemoteServer? = nil
    var updates: UpdateCenter? = nil
    let videoLayer: VideoLayer
    let actions: PlayerActions
    let chrome: WindowChrome
    var overlay = OverlayController()
    var isVideoMode = true
    @State private var isDropTargeted = false

    func videoMode(_ active: Bool) -> PlayerView {
        var copy = self
        copy.isVideoMode = active
        return copy
    }

    private var canHideControls: Bool {
        !model.isScreensaverEngaged && model.hasMedia && !model.isShowingHome && !model.paused
            && !model.isAtEnd
            && model.errorMessage == nil && pairing?.prompt == nil && !model.isShowingConnectPhone
            && model.trackController.presentation == nil && !model.trackController.isChoosingFile
    }

    var body: some View {
        ZStack {
            Palette.base
            if isVideoMode || model.hasMedia || model.isLoading {
                VideoView(videoLayer: videoLayer)
                // Transparent layer catches double-click: video NSView does not forward SwiftUI gestures.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if !model.isShowingHome { model.toggleFullscreen() }
                    }
                content
                    .accessibilityHidden(model.trackController.presentation != nil)
            }
            if model.screensaver == .matrix { MatrixScreensaverView(model: model) }
            if model.hasMedia, !model.isShowingHome, model.trackController.presentation != nil,
                pairing?.prompt == nil
            {
                TrackPanelsOverlay(controller: model.trackController)
            }
            if model.isShowingConnectPhone, !model.isScreensaverEngaged, let remote,
                pairing?.prompt == nil
            {
                ConnectPhoneView(remote: remote) { model.isShowingConnectPhone = false }
            }
            if let pairing, let prompt = pairing.prompt {
                PairingCodeView(prompt: prompt) { pairing.decline() }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if isDropTargeted { DropHighlight() }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.25), value: model.hasMedia)
        .animation(.easeOut(duration: 0.25), value: model.isShowingHome)
        .animation(.spring(duration: 0.35), value: pairing?.prompt)
        .onChange(of: pairing?.prompt) { _, prompt in
            if prompt != nil { model.isShowingConnectPhone = false }
        }
        .onChange(of: (model.hasMedia && !model.isShowingHome) || model.isLoading) { _, active in
            if active { model.isShowingConnectPhone = false }
        }
        .onChange(of: model.isScreensaverEngaged) { _, engaged in
            if engaged {
                model.isShowingConnectPhone = false
                overlay.set(.titlebar, active: false)
            }
        }
        .onContinuousHover { phase in
            guard !model.isScreensaverEngaged else { return }
            switch phase {
            case .active:
                overlay.set(.titlebar, active: chrome.isPointerInTitlebar())
                overlay.activity()
            case .ended:
                if chrome.isPointerInTitlebar() {
                    overlay.set(.titlebar, active: true)
                    overlay.activity()
                } else {
                    overlay.set(.titlebar, active: false)
                    overlay.pointerLeft()
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: VideoFiles.isVideo) else {
                model.errorMessage = L10n.text("Kinrox opens video files only.")
                return false
            }
            actions.open(url)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .onChange(of: canHideControls, initial: true) { _, canHide in overlay.canHide = canHide }
        .onDisappear { overlay.canHide = false }
        .onChange(of: controlsVisible, initial: true) { _, visible in
            chrome.setControlsVisible(visible)
        }
        .onChange(of: model.displayTitle, initial: true) { _, title in chrome.setTitle(title) }
        .preferredColorScheme(.dark)
        .alert(
            L10n.text("Failed to open video"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L10n.text("Dismiss")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.screensaver == .matrix {
            EmptyView()
        } else if model.hasMedia, !model.isShowingHome {
            PlaybackOverlay(
                model: model, recents: recents, remote: remote, updates: updates, overlay: overlay,
                actions: actions
            )
            .opacity(overlay.isVisible ? 1 : 0)
            .allowsHitTesting(overlay.isVisible)
        } else if model.isLoading {
            Label(L10n.text("Opening video…"), systemImage: "film")
                .font(KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .kinroxGlass(in: Capsule())
        } else {
            WelcomeView(
                model: model, recents: recents, actions: actions, remote: remote, updates: updates,
                connectPhone: { model.isShowingConnectPhone = true }
            )
            .transition(.opacity)
        }
    }

    private var controlsVisible: Bool {
        model.screensaver == .off && (overlay.isVisible || !model.hasMedia || model.isShowingHome)
    }
}

/// Layers atop playing video: scrims, title, and controls bar.
private struct PlaybackOverlay: View {
    let model: PlayerViewModel
    let recents: RecentFilesStore?
    let remote: RemoteServer?
    let updates: UpdateCenter?
    let overlay: OverlayController
    let actions: PlayerActions

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom
                )
                .frame(height: 140)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom
                )
                .frame(height: 300)
            }
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                TitleHeader(title: model.displayTitle, caption: model.playlistCaption)
                    .padding(.top, 14)
                    .padding(.horizontal, 236)
                if let updates, let update = updates.available,
                    updates.showsPill(paused: model.paused)
                {
                    // Below the remote chip when it is shown, so narrow windows never overlap.
                    UpdatePill(center: updates, update: update)
                        .padding(.top, remote?.controllerText == nil ? 20 : 52)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer(minLength: 0)
                ControlsBar(model: model, recents: recents, overlay: overlay, actions: actions)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
            .animation(.spring(duration: 0.35), value: updates?.showsPill(paused: model.paused))
            VStack {
                HStack {
                    OverlayHomeButton(overlay: overlay) { _ = model.showHome() }
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 14)
            .padding(.leading, 20)
            if let text = remote?.controllerText {
                VStack {
                    HStack {
                        Spacer()
                        RemoteStatusView(text: text, online: true).frame(maxWidth: 280)
                    }
                    Spacer()
                }.padding(.top, 54).padding(.trailing, 20).allowsHitTesting(false)
            }
        }
    }
}

private struct OverlayHomeButton: View {
    let overlay: OverlayController
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(L10n.text("Video Home"))
                    .font(KinroxFont.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                Text("·  \(L10n.text("Recent"))")
                    .font(KinroxFont.caption)
                    .foregroundStyle(Palette.textSecondary)
                Text("Esc")
                    .font(KinroxFont.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.28), in: Capsule())
            .kinroxGlass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { overlay.set(.hover, active: $0) }
        .help(L10n.text("Home & Recent"))
        .accessibilityLabel(L10n.text("Home & Recent"))
        .accessibilityIdentifier("video-home-overlay-button")
    }
}

private struct TitleHeader: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
            if !caption.isEmpty {
                Text(caption)
                    .font(KinroxFont.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .shadow(color: .black.opacity(0.4), radius: 6)
    }
}

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            Palette.ember.opacity(0.06)
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    Palette.ember, style: StrokeStyle(lineWidth: 2, dash: [10, 8])
                )
                .padding(12)
            Label(L10n.text("Release to open"), systemImage: "arrow.down.circle")
                .font(KinroxFont.title)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .kinroxGlass(in: Capsule(), tint: Palette.ember.opacity(0.25))
        }
        .allowsHitTesting(false)
    }
}
