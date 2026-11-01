import SwiftUI

/// Network-backed sliders commit once on release; dragging never floods Spotify.
struct MusicSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    let step: Double
    let commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        Slider(
            value: Binding(
                get: { min(range.upperBound, max(range.lowerBound, draft ?? value)) },
                set: { draft = $0 }),
            in: range,
            onEditingChanged: { editing in
                if !editing, let draft {
                    commit(draft)
                    self.draft = nil
                }
            }
        )
        .accessibilityLabel(label)
        .accessibilityValue(Int(draft ?? value).formatted())
        .accessibilityAdjustableAction { direction in
            commit(
                min(
                    range.upperBound,
                    max(range.lowerBound, value + (direction == .increment ? step : -step))))
        }
    }
}
