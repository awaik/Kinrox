import SwiftUI

/// Pairing code overlay over video (Figma: Mac / Pairing - PIN).
/// Code valid for 2 minutes; window closes automatically upon expiration.
struct PairingCodeView: View {
    let prompt: PairingPrompt
    let decline: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                card(remaining: prompt.remaining(at: context.date))
            }
        }
    }

    private func card(remaining: TimeInterval) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 64, height: 64)
                .background(Palette.emberDiagonal, in: RoundedRectangle(cornerRadius: 22))
                .emberGlow()
            Text(L10n.text("Remote Connection"))
                .font(KinroxFont.titleLarge())
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, 20)
            Text(
                L10n.format(
                    "%@ wants to control Kinrox. Enter this code on your phone.", prompt.deviceName)
            )
            .font(KinroxFont.body)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
            digits.padding(.top, 24)
            HStack(spacing: 8) {
                Circle()
                    .trim(from: 0, to: remaining / PairingPrompt.lifetime)
                    .stroke(Palette.ember, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 14)
                Text(L10n.format("Code expires in %@", TimeFormat.string(remaining)))
                    .font(KinroxFont.caption.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.top, 16)
            Button(action: decline) {
                Text(L10n.text("Reject"))
                    .font(KinroxFont.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Palette.glass, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .keyboardShortcut(.cancelAction)
            .padding(.top, 28)
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 460)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 34))
        .kinroxGlass(in: RoundedRectangle(cornerRadius: 34))
        .accessibilityElement(children: .contain)
    }

    private var digits: some View {
        HStack(spacing: 8) {
            ForEach(Array(prompt.code.enumerated()), id: \.offset) { index, digit in
                if index == 3 { Spacer().frame(width: 8) }
                Text(String(digit))
                    .font(KinroxFont.timeLarge(36))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 52, height: 68)
                    .background(Palette.glass, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format("Code %@", prompt.code.map(String.init).joined(separator: " ")))
    }
}
