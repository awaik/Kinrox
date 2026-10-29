import SwiftUI

struct MatrixScreensaverView: View {
    let model: PlayerViewModel

    var body: some View {
        MatrixRainView()
            .overlay(alignment: .bottom) {
                if model.screensaverPresentation.showsHint {
                    Text(
                        model.hasMedia
                            ? L10n.text("Esc — exit · Movie paused") : L10n.text("Esc — exit")
                    )
                    .font(KinroxFont.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.9), in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.strokeGlass))
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Matrix screensaver. Press Escape to exit."))
    }
}
