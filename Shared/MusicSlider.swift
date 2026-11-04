import SwiftUI

/// Network-backed sliders commit once on release; dragging never floods Spotify.
struct MusicSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    let step: Double
    var valueKnown = true
    let commit: (Double) -> Void
    @State private var draft: Double?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if valueKnown {
            slider
        } else {
            Capsule().fill(.secondary.opacity(0.3)).frame(height: 4)
                .frame(height: 16)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue("—")
        }
    }

    private var currentValue: Double {
        let raw = draft ?? value
        guard raw.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, raw))
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (currentValue - range.lowerBound) / span))
    }

    private var slider: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let filled = width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3)).frame(height: 4)
                Capsule().fill(.tint).frame(width: max(4, filled), height: 4)
                Circle()
                    .fill(Palette.textPrimary)
                    .frame(width: 12, height: 12)
                    .offset(x: min(max(0, filled - 6), max(0, width - 12)))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        draft = value(at: drag.location.x, width: width)
                    }
                    .onEnded { drag in
                        guard isEnabled else { return }
                        let target = value(at: drag.location.x, width: width)
                        draft = nil
                        commit(target)
                    }
            )
        }
        .frame(height: 16)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Int(currentValue).formatted())
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            commit(
                min(
                    range.upperBound,
                    max(range.lowerBound, value + (direction == .increment ? step : -step))))
        }
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        let clamped = min(1, max(0, Double(x / width)))
        return range.lowerBound + clamped * (range.upperBound - range.lowerBound)
    }
}
