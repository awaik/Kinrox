import RemoteProtocol
import SwiftUI

/// Figma page 07: one Matrix card and one state-dependent action, controlled by Mac state.
struct ScreensaverControls: View {
    @Bindable var store: RemoteAppModel
    @State private var isSending = false
    private var active: Bool { store.state.screensaver == .matrix }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Screensavers"))
                    .font(KinroxFont.titleLarge(22))
                    .foregroundStyle(Palette.textPrimary)
                Text(
                    active
                        ? L10n.format("Matrix is running on %@", store.selected?.name ?? "Mac")
                        : L10n.format("On %@", store.selected?.name ?? "Mac")
                )
                .font(KinroxFont.body)
                .foregroundStyle(Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                MatrixRainView(animated: false).aspectRatio(16.0 / 9, contentMode: .fit)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Matrix").font(KinroxFont.titleLarge(22))
                        .foregroundStyle(Palette.textPrimary)
                    Text(
                        active
                            ? L10n.text("Active on Mac. No sound.")
                            : L10n.text("Falling green code. No sound.")
                    )
                    .font(KinroxFont.body)
                    .foregroundStyle(active ? Palette.online : Palette.textSecondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            }
            .background(Palette.glass)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.strokeGlass))
            Text(context)
                .font(KinroxFont.body)
                .foregroundStyle(Palette.textSecondary)
                .frame(minHeight: 40, alignment: .topLeading)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    isSending = true
                    store.setScreensaver(active ? .off : .matrix) { _ in isSending = false }
                } label: {
                    HStack {
                        if isSending { ProgressView().tint(Palette.textPrimary) }
                        Text(active ? L10n.text("Turn Off Matrix") : L10n.text("Turn On Matrix"))
                            .font(KinroxFont.title)
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background {
                        if active {
                            Capsule().fill(Palette.glassStrong)
                        } else {
                            Capsule().fill(Palette.emberDiagonal)
                        }
                    }
                    .overlay(Capsule().strokeBorder(Palette.strokeGlass))
                }
                .buttonStyle(PressableStyle())
                .disabled(!store.controlsEnabled || !store.supportsScreensavers || isSending)
                .opacity(store.controlsEnabled && store.supportsScreensavers ? 1 : 0.4)
                Text(
                    active && store.state.hasMedia
                        ? L10n.text("The movie stays paused.")
                        : L10n.text("On Mac: Esc exits the screensaver.")
                )
                .font(KinroxFont.caption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 36)
    }

    private var context: String {
        if store.hasState && !store.supportsScreensavers {
            return L10n.text("Update Kinrox on Mac to use screensavers.")
        }
        guard store.state.hasMedia else { return "" }
        if active {
            return L10n.format(
                "%@ · Paused at %@", store.state.title,
                TimeFormat.elapsed(store.state.position, duration: store.state.duration))
        }
        return L10n.text("Starting pauses the movie. Your position is preserved.")
    }
}
