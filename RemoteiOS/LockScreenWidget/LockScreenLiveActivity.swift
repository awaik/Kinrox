import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LockScreenWidgetBundle: WidgetBundle {
    var body: some Widget {
        LockScreenLiveActivity()
    }
}

/// Lock Screen card and Dynamic Island (Figma `212:304`). Tapping outside the buttons
/// opens the remote, which is the system default for a Live Activity.
struct LockScreenLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockScreenAttributes.self) { context in
            LockScreenCard(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Palette.elevated.opacity(0.94))
                .activitySystemActionForegroundColor(Palette.textPrimary)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LockScreenArtwork(state: state, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        LockScreenMark(size: 16)
                        LockScreenPlayGlyph(state: state)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    let presentation = LockScreenPresentation(
                        state: state, isStale: context.isStale)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(presentation.title)
                            .font(KinroxFont.bodyStrong)
                            .foregroundStyle(Palette.textPrimary)
                        Text("\(presentation.subtitle) · \(state.macName)")
                            .font(KinroxFont.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if state.phase != .unreachable {
                            LockScreenProgress(state: state, isStale: context.isStale)
                        }
                        LockScreenControlRow(state: state, compact: true)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                LockScreenArtwork(state: state, size: 24)
            } compactTrailing: {
                LockScreenPlayGlyph(state: state)
            } minimal: {
                LockScreenPlayGlyph(state: state)
            }
            .keylineTint(Palette.ember)
        }
    }
}

/// Compact play state: an equalizer while playing, a pause glyph when paused.
struct LockScreenPlayGlyph: View {
    let state: LockScreenAttributes.ContentState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(state.phase == .unreachable ? Palette.textTertiary : Palette.ember)
            .accessibilityLabel(state.paused ? L10n.text("Paused") : L10n.text("Playback"))
    }

    private var symbol: String {
        if state.phase == .unreachable { return "wifi.slash" }
        return state.paused ? "pause.fill" : "waveform"
    }
}
