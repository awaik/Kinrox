import SwiftUI

struct PlayerRootView: View {
    @Bindable var session: PlayerSession
    let video: PlayerView
    let modeChanged: (AppMode) -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !video.model.isFullscreen {
                    AppModePicker(session: session).frame(width: 198).frame(maxWidth: .infinity)
                        .frame(height: 52).background(Palette.elevated)
                        .onContinuousHover { phase in
                            guard !video.model.isScreensaverEngaged else { return }
                            switch phase {
                            case .active:
                                video.overlay.set(.titlebar, active: true)
                                video.overlay.activity()
                            case .ended:
                                if !video.chrome.isPointerInTitlebar() {
                                    video.overlay.set(.titlebar, active: false)
                                }
                            }
                        }
                }
                video
            }.opacity(session.mode == .video ? 1 : 0)
                .allowsHitTesting(session.mode == .video).accessibilityHidden(
                    session.mode != .video)
            if session.mode == .music { MusicView(session: session, model: session.music) }
        }.ignoresSafeArea().preferredColorScheme(.dark)
            .onChange(of: session.mode, initial: true) { _, mode in modeChanged(mode) }
    }
}

struct AppModePicker: View {
    @Bindable var session: PlayerSession
    var body: some View {
        HStack(spacing: 2) {
            modeButton(.video, title: L10n.text("Video"))
            modeButton(.music, title: "Spotify")
        }.padding(2).frame(height: 30)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("Playback mode"))
    }

    private func modeButton(_ mode: AppMode, title: String) -> some View {
        Button {
            session.mode = mode
        } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(session.mode == mode ? Palette.textPrimary : Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .background(
                    session.mode == mode ? Palette.glassStrong : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(session.mode == mode ? .isSelected : [])
    }
}
