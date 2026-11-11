import SwiftUI
import WidgetKit

/// Figma `214:1032` (LA / Lock Screen card): 370 × 160 pt, padding 12/14/12.
struct LockScreenCard: View {
    let state: LockScreenAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LockScreenHeader(state: state, isStale: isStale)
            if state.phase != .unreachable {
                LockScreenProgress(state: state, isStale: isStale)
            }
            LockScreenControlRow(state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct LockScreenHeader: View {
    let state: LockScreenAttributes.ContentState
    let isStale: Bool

    private var presentation: LockScreenPresentation {
        .init(state: state, isStale: isStale)
    }

    var body: some View {
        HStack(spacing: 12) {
            LockScreenArtwork(state: state)
                .opacity(presentation.showsNext ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    LockScreenMark(size: 12)
                    Text("Kinrox · \(state.macName)")
                        .font(KinroxFont.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if state.paused, state.phase != .unreachable {
                        Text(L10n.text("Paused"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.glassStrong, in: Capsule())
                    }
                }
                Text(presentation.title)
                    .font(KinroxFont.title)
                    .foregroundStyle(Palette.textPrimary.opacity(presentation.showsNext ? 0.7 : 1))
                    .lineLimit(1)
                Text(presentation.subtitle)
                    .font(KinroxFont.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

}

/// The wire protocol carries no artwork, so the tile shows the media kind.
struct LockScreenArtwork: View {
    let state: LockScreenAttributes.ContentState
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill(state.phase == .unreachable ? Palette.glass : Palette.glassStrong)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(
                        state.phase == .unreachable ? Palette.textTertiary : Palette.flame)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if state.phase == .unreachable { return "wifi.slash" }
        return state.media == .music ? "music.note" : "play.rectangle.fill"
    }
}

struct LockScreenMark: View {
    let size: CGFloat

    var body: some View {
        Image("KinroxMark")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

/// Figma `213:419` (LA / Progress): live, frozen on pause, and stale.
struct LockScreenProgress: View {
    let state: LockScreenAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isStale && state.showsTimer {
                Capsule().fill(Palette.glass).frame(height: 4)
                Label(L10n.text("Updates when you tap"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            } else if state.showsTimer {
                timer(countsDown: false)
                ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false) {
                } currentValueLabel: {
                }
                .progressViewStyle(.linear)
                .tint(Palette.ember)
                HStack(spacing: 0) {
                    Text(verbatim: "−")
                    timer(countsDown: true)
                }
                .font(KinroxFont.time)
                .foregroundStyle(Palette.textTertiary)
            } else {
                frozen(TimeFormat.elapsed(state.position, duration: state.duration))
                ProgressView(
                    value: min(state.position, state.duration), total: max(state.duration, 1)
                )
                .progressViewStyle(.linear)
                .tint(Palette.textTertiary)
                frozen(TimeFormat.remaining(position: state.position, duration: state.duration))
            }
        }
        .frame(height: 16)
    }

    private func timer(countsDown: Bool) -> some View {
        Text(timerInterval: state.startDate...state.endDate, countsDown: countsDown)
            .font(KinroxFont.time)
            .monospacedDigit()
            .foregroundStyle(Palette.textTertiary)
            .frame(width: state.duration >= 3600 ? 56 : 38, alignment: .leading)
    }

    private func frozen(_ text: String) -> some View {
        Text(verbatim: text)
            .font(KinroxFont.time)
            .monospacedDigit()
            .foregroundStyle(Palette.textTertiary)
    }
}
