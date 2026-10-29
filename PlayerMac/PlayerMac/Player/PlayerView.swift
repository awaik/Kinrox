import SwiftUI

/// Root window view: video, glass control bar overlay, empty welcome screen.
struct PlayerView: View {
    @Bindable var model: PlayerViewModel
    let recents: RecentFilesStore?
    let pairing: PairingCenter?
    var remote: RemoteServer? = nil
    let videoLayer: VideoLayer
    let actions: PlayerActions
    let chrome: WindowChrome
    @State private var overlay = OverlayController()
    @State private var isDropTargeted = false
    @State private var showsConnect = false

    private var canHideControls: Bool {
        model.hasMedia && !model.paused && !model.isAtEnd
            && model.errorMessage == nil && pairing?.prompt == nil && !showsConnect
            && model.trackController.presentation == nil && !model.trackController.isChoosingFile
    }

    var body: some View {
        ZStack {
            Palette.base
            VideoView(videoLayer: videoLayer)
            // Transparent layer catches double-click: video NSView does not forward SwiftUI gestures.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.toggleFullscreen() }
            content
                .accessibilityHidden(model.trackController.presentation != nil)
            if model.hasMedia, model.trackController.presentation != nil, pairing?.prompt == nil {
                TrackPanelsOverlay(controller: model.trackController)
            }
            if showsConnect, let remote, pairing?.prompt == nil {
                ConnectPhoneView(remote: remote) { showsConnect = false }
            }
            if let pairing, let prompt = pairing.prompt {
                PairingCodeView(prompt: prompt) { pairing.decline() }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if isDropTargeted { DropHighlight() }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.25), value: model.hasMedia)
        .animation(.spring(duration: 0.35), value: pairing?.prompt)
        .onChange(of: pairing?.prompt) { _, prompt in if prompt != nil { showsConnect = false } }
        .onChange(of: model.hasMedia || model.isLoading) { _, active in
            if active { showsConnect = false }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: overlay.activity()
            case .ended: overlay.pointerLeft()
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
        .onChange(of: overlay.isVisible || !model.hasMedia, initial: true) { _, visible in
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
        if model.hasMedia {
            PlaybackOverlay(
                model: model, recents: recents, remote: remote, overlay: overlay, actions: actions
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
                recents: recents, actions: actions, remote: remote,
                connectPhone: { showsConnect = true }
            )
            .transition(.opacity)
        }
    }
}

/// Layers atop playing video: scrims, title, and controls bar.
private struct PlaybackOverlay: View {
    let model: PlayerViewModel
    let recents: RecentFilesStore?
    let remote: RemoteServer?
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
                    .padding(.horizontal, 96)
                Spacer(minLength: 0)
                ControlsBar(model: model, recents: recents, overlay: overlay, actions: actions)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
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
