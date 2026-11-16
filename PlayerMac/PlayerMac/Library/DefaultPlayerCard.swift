import AppKit
import SwiftUI

/// Figma 312:454, first card in Settings. States: not default, partial, default, failed.
struct DefaultPlayerCard: View {
    @State private var player = DefaultVideoPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "play.rectangle").font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Default Video Player")).font(KinroxFont.bodyStrong)
                    Text(L10n.text("Videos open in Kinrox with a double-click in Finder."))
                        .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !player.isDefault {
                    Button {
                        Task { await player.makeDefault() }
                    } label: {
                        Text(player.failed ? L10n.text("Retry") : L10n.text("Make Kinrox Default"))
                            .font(KinroxFont.caption.weight(.semibold))
                            .foregroundStyle(Palette.base)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Palette.ember, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.isChanging)
                    .opacity(player.isChanging ? 0.6 : 1)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            Divider()
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(status).font(KinroxFont.caption)
                    .foregroundStyle(player.failed ? Palette.flame : Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
        .onAppear { player.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            player.refresh()
        }
    }

    private var status: String {
        if player.failed { return L10n.text("Couldn’t change the default app. Please try again.") }
        if player.isDefault { return L10n.text("Kinrox opens your videos") }
        return L10n.format("Open in other apps: %@", player.otherFormats.joined(separator: ", "))
    }

    private var dotColor: Color {
        if player.failed { return Palette.flame }
        if player.isDefault { return Palette.online }
        return player.otherFormats.count < DefaultVideoPlayer.formats.count
            ? Palette.ember : Palette.textTertiary
    }
}
