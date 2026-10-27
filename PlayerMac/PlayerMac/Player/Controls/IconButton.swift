import SwiftUI

/// Round icon button: transparent background with glass highlight on hover.
struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 36
    var iconSize: CGFloat = 15
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(Palette.textPrimary.opacity(isEnabled ? 1 : 0.32))
        .background(Circle().fill(isHovering && isEnabled ? Palette.glassStrong : .clear))
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Main play/pause button: warm cream circle with glow.
struct PlayPauseButton: View {
    let paused: Bool
    var size: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Palette.base)
                .offset(x: paused ? size * 0.03 : 0)
                .frame(width: size, height: size)
                .background(Circle().fill(Palette.textPrimary))
                .contentShape(Circle())
                .emberGlow(radius: 16, opacity: 0.35, y: 6)
        }
        .buttonStyle(PressScaleStyle())
        .help(paused ? L10n.text("Play (Space)") : L10n.text("Pause (Space)"))
        .accessibilityLabel(paused ? L10n.text("Play") : L10n.text("Pause"))
    }
}

/// Press slightly compresses button for responsive feedback.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
