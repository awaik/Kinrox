import SwiftUI

struct PlayerRootView: View {
    static let modePickerWidth: CGFloat = 198
    static let navLeadingPadding: CGFloat = 92

    static func leftNavBudget(for width: CGFloat) -> CGFloat {
        max(0, (width - modePickerWidth) / 2 - navLeadingPadding - 12)
    }

    @Bindable var session: PlayerSession
    let video: PlayerView
    let modeChanged: (AppMode) -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !video.model.isFullscreen {
                    GeometryReader { proxy in
                        let leftBudget = Self.leftNavBudget(for: proxy.size.width)
                        ZStack {
                            AppModePicker(session: session).frame(width: Self.modePickerWidth)
                            if video.model.hasMedia, !video.model.isScreensaverEngaged {
                                HStack {
                                    TitlebarVideoNavButton(
                                        model: video.model, availableWidth: leftBudget)
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, Self.navLeadingPadding)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Palette.elevated)
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
                video.videoMode(session.mode == .video)
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
            if mode == .video, session.mode == .video,
                let player = session.model, player.hasMedia, !player.isScreensaverEngaged
            {
                _ = player.toggleHome()
            } else {
                session.mode = mode
            }
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

struct TitlebarVideoNavButton: View {
    let model: PlayerViewModel
    var availableWidth: CGFloat = 360

    var body: some View {
        if model.isShowingHome {
            let fullTitle = L10n.format(
                "%@ · %@", L10n.text("Back to Video"), TimeFormat.string(model.position))
            Button {
                _ = model.returnToVideo()
            } label: {
                ViewThatFits(in: .horizontal) {
                    returnPill(text: fullTitle)
                    returnPill(text: TimeFormat.string(model.position))
                    returnPill(text: nil)
                }
            }
            .buttonStyle(.plain)
            .help(fullTitle)
            .accessibilityLabel(fullTitle)
            .accessibilityIdentifier("titlebar-return-video-button")
            .frame(maxWidth: availableWidth, alignment: .leading)
        } else {
            let fullTitle = L10n.text("Home & Recent")
            Button {
                _ = model.showHome()
            } label: {
                ViewThatFits(in: .horizontal) {
                    homePill(text: fullTitle)
                    homePill(text: L10n.text("Recent"))
                    homePill(text: nil)
                }
            }
            .buttonStyle(.plain)
            .help(fullTitle)
            .accessibilityLabel(fullTitle)
            .accessibilityIdentifier("titlebar-video-home-button")
            .frame(maxWidth: availableWidth, alignment: .leading)
        }
    }

    private func returnPill(text: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
            if let text {
                Text(text)
                    .font(KinroxFont.caption.monospacedDigit())
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(Palette.flame)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.ember.opacity(0.45), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func homePill(text: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
            if let text {
                Text(text)
                    .font(KinroxFont.caption)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.strokeGlass, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
