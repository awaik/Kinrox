import AppIntents
import SwiftUI
import WidgetKit

/// Figma `213:820` (LA / Control row): volume −, previous/−10, play/pause, next/+10, volume +.
struct LockScreenControlRow: View {
    let state: LockScreenAttributes.ContentState
    var compact = false

    var body: some View {
        HStack {
            button(.volumeDown, enabled: state.canVolume)
            Spacer(minLength: 0)
            button(state.media == .music ? .previous : .back10, enabled: state.canPrevious)
            Spacer(minLength: 0)
            button(.togglePause, enabled: true)
            Spacer(minLength: 0)
            button(state.media == .music ? .next : .forward10, enabled: state.canNext)
            Spacer(minLength: 0)
            button(.volumeUp, enabled: state.canVolume)
        }
    }

    private func button(_ action: LockScreenAction, enabled: Bool) -> some View {
        LockScreenControlButton(
            action: action, paused: state.paused, compact: compact,
            enabled: enabled && state.phase != .unreachable,
            sending: state.phase == .sending && state.sending == action)
    }
}

/// Figma `212:415` (LA / Control button): 40 pt glass circle, 46 pt ember for play/pause.
struct LockScreenControlButton: View {
    let action: LockScreenAction
    let paused: Bool
    var compact = false
    let enabled: Bool
    let sending: Bool

    private var primary: Bool { action == .togglePause }
    private var size: CGFloat { (primary ? 46 : 40) - (compact ? 4 : 0) }

    var body: some View {
        Button(intent: LockScreenControlIntent(action)) {
            ZStack {
                Circle().fill(
                    primary ? AnyShapeStyle(Palette.ember) : AnyShapeStyle(Palette.glassStrong))
                if sending {
                    Circle().strokeBorder(Palette.flame, lineWidth: 1.5)
                }
                Image(systemName: symbol)
                    .font(.system(size: primary ? 18 : 15, weight: .semibold))
                    .foregroundStyle(primary ? Palette.base : Palette.textPrimary)
                    .opacity(sending ? 0.35 : 1)
            }
            .frame(width: size, height: size)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch action {
        case .previous: "backward.end.fill"
        case .togglePause: paused ? "play.fill" : "pause.fill"
        case .next: "forward.end.fill"
        case .back10: "gobackward.10"
        case .forward10: "goforward.10"
        case .volumeDown: "speaker.minus.fill"
        case .volumeUp: "speaker.plus.fill"
        }
    }

    private var label: String {
        switch action {
        case .previous: L10n.text("Previous track")
        case .togglePause: paused ? L10n.text("Play") : L10n.text("Pause")
        case .next: L10n.text("Next track")
        case .back10: L10n.format("Back %@ seconds", 10.formatted())
        case .forward10: L10n.format("Forward %@ seconds", 10.formatted())
        case .volumeDown: L10n.text("Volume down")
        case .volumeUp: L10n.text("Volume up")
        }
    }
}
