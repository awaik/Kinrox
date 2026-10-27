import SwiftUI

/// Mute button and compact volume slider 0–100.
struct VolumeControl: View {
    let model: PlayerViewModel
    @State private var restoreVolume: Double = 100

    private var icon: String {
        switch model.volume {
        case 0: "speaker.slash.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            IconButton(
                systemName: icon, help: model.volume == 0 ? L10n.text("Unmute") : L10n.text("Mute")
            ) {
                if model.volume > 0 {
                    restoreVolume = model.volume
                    model.setVolume(0)
                } else {
                    model.setVolume(max(restoreVolume, PlayerViewModel.volumeStep))
                }
            }
            .frame(width: 36)
            MiniSlider(value: model.volume / 100) { model.setVolume(($0 * 100).rounded()) }
                .frame(width: 96, height: 16)
                .accessibilityLabel(L10n.text("Volume"))
                .accessibilityValue("\(Int(model.volume))")
                .accessibilityAdjustableAction { direction in
                    model.changeVolume(
                        by: direction == .increment
                            ? PlayerViewModel.volumeStep : -PlayerViewModel.volumeStep)
                }
        }
    }
}

/// Thin slider with cream fill.
struct MiniSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = min(1, max(0, value))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.glassStrong).frame(height: 4)
                Capsule().fill(Palette.textPrimary).frame(width: width * fraction, height: 4)
                Circle()
                    .fill(Palette.textPrimary)
                    .frame(width: 12, height: 12)
                    .offset(x: width * fraction - 6)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    onChange(min(1, max(0, drag.location.x / width)))
                })
        }
    }
}
