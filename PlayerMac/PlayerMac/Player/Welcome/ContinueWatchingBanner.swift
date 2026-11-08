import SwiftUI

/// Paused movie banner at the top of WelcomeView (Figma page 10: `Video / Continue Watching Banner`).
struct ContinueWatchingBanner: View {
    let model: PlayerViewModel
    var availableWidth: CGFloat = 1032

    private var isCompact: Bool { availableWidth < 820 }

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.position / model.duration))
    }

    private var statusText: String {
        if model.duration > 0 {
            return L10n.format(
                "Now open · Paused at %@ of %@",
                TimeFormat.string(model.position),
                TimeFormat.string(model.duration))
        }
        return L10n.text("Now open · Paused")
    }

    var body: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        thumbnail
                        movieInfo
                    }
                    actionButtons
                }
            } else {
                HStack(spacing: 20) {
                    thumbnail
                    movieInfo
                    Spacer(minLength: 8)
                    actionButtons
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 1032, alignment: .leading)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 20))
        .kinroxGlass(in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Palette.ember.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("continue-watching-banner")
    }

    private var thumbnail: some View {
        Button {
            _ = model.returnToVideo()
        } label: {
            StillArtwork(seed: StillArtwork.seed(for: model.displayTitle))
                .frame(width: 144, height: 80)
                .overlay(alignment: .topLeading) {
                    Text(
                        L10n.format(
                            "%@ · %@", L10n.text("Paused"), TimeFormat.string(model.position))
                    )
                    .font(KinroxFont.caption.monospacedDigit())
                    .foregroundStyle(Palette.flame)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 5))
                    .padding(7)
                }
                .overlay(alignment: .bottomLeading) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.65))
                            Rectangle()
                                .fill(Palette.emberGradient)
                                .frame(width: proxy.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private var movieInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .overlineStyle(Palette.flame)
                .lineLimit(1)
            Text(model.displayTitle)
                .font(KinroxFont.title)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !model.playlistCaption.isEmpty {
                Text(model.playlistCaption)
                    .font(KinroxFont.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                _ = model.returnToVideo()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(L10n.text("Back to Video"))
                        .lineLimit(1)
                    Text("Esc")
                        .font(KinroxFont.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .background(Palette.emberGradient, in: Capsule())
                .emberGlow(radius: 14, opacity: 0.4, y: 6)
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityIdentifier("continue-watching-resume-button")

            Button {
                _ = model.closeVideo()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.text("Close Video"))
                        .lineLimit(1)
                }
                .font(KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .kinroxGlass(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityIdentifier("continue-watching-close-button")
        }
    }
}

/// Compact bar for opening another video while a movie is paused on the Home screen.
struct QuickOpenBar: View {
    let actions: PlayerActions
    let remote: RemoteServer?
    let connectPhone: () -> Void
    var availableWidth: CGFloat = 1032

    private var isCompact: Bool { availableWidth < 760 }

    var body: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 12) {
                    promptText
                    buttons
                }
            } else {
                HStack(spacing: 16) {
                    promptText
                    Spacer(minLength: 12)
                    buttons
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 1032, alignment: .leading)
        .background(Palette.glass.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private var promptText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("Want to watch another video?"))
                .font(KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Text(
                L10n.text(
                    "Choose a card from history below, drop a file into the window, or open via dialog."
                )
            )
            .font(KinroxFont.caption)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(2)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: actions.openFile) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(L10n.text("Open File"))
                        .lineLimit(1)
                    Text("⌘O")
                        .font(KinroxFont.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.24), in: Capsule())
                }
                .font(KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .kinroxGlass(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())

            if remote != nil {
                RemotePillButton(
                    title: L10n.text("Connect iPhone"), icon: "wifi", action: connectPhone)
            }
        }
    }
}
