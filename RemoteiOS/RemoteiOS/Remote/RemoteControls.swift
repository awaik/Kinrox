import SwiftUI

/// Thick scrubber bar. While dragging, shows target position;
/// seekAbsolute sent on release.
struct RemoteScrubber: View {
    let position: Double
    let duration: Double
    @Binding var target: Double?
    let commit: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(1, max(0, (target ?? position) / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.glassStrong).frame(height: 8)
                Capsule().fill(Palette.emberGradient).frame(
                    width: max(8, width * fraction), height: 8)
                Circle()
                    .fill(Palette.textPrimary)
                    .frame(width: 24, height: 24)
                    .emberGlow(radius: 12, opacity: 0.6, y: 0)
                    .scaleEffect(target == nil ? 1 : 1.2)
                    .offset(x: min(max(0, width - 24), max(0, width * fraction - 12)))
            }
            .frame(width: width, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        target = min(1, max(0, value.location.x / width)) * duration
                    }
                    .onEnded { value in
                        commit(min(1, max(0, value.location.x / width)) * duration)
                        target = nil
                    }
            )
            .animation(.spring(duration: 0.2), value: target == nil)
        }
        .frame(height: 44)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Position"))
        .accessibilityValue(TimeFormat.elapsed(position, duration: duration))
        .accessibilityAdjustableAction { direction in
            commit(position + (direction == .increment ? 10 : -10))
        }
    }
}

/// Round relative seek button (Figma: Control/Seek Button).
struct SeekButton: View {
    let seconds: Double
    let action: () -> Void

    private var label: String { (seconds < 0 ? "−" : "+") + String(Int(abs(seconds))) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(label).font(KinroxFont.title.monospacedDigit())
                Text(L10n.text("s")).font(KinroxFont.caption).foregroundStyle(Palette.textTertiary)
            }
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(Circle())
            .kinroxGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(
            seconds < 0
                ? L10n.format("Back %@ seconds", Int(-seconds).formatted())
                : L10n.format("Forward %@ seconds", Int(seconds).formatted()))
    }
}

/// Mac volume glass capsule. Commands max 10 times per second.
struct VolumeBar: View {
    let volume: Double
    let change: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill")
            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = min(1, max(0, (dragValue ?? volume) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.glassStrong).frame(height: 6)
                    Capsule().fill(Palette.textPrimary).frame(width: width * fraction, height: 6)
                }
                .frame(width: width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let next = (min(1, max(0, value.location.x / width)) * 100).rounded()
                            dragValue = next
                            change(next)
                        }
                        .onEnded { _ in
                            if let dragValue { change(dragValue) }
                            dragValue = nil
                        }
                )
            }
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 18)
        .frame(height: 56)
        .kinroxGlass(in: Capsule())
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Volume Mac"))
        .accessibilityValue("\(Int(volume))")
        .accessibilityAdjustableAction { direction in
            change(volume + (direction == .increment ? 5 : -5))
        }
    }
}

/// Wide glass button with icon and label.
struct PillButton: View {
    let title: String
    let systemImage: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(KinroxFont.bodyStrong)
                .lineLimit(2).minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(isOn ? Palette.flame : Palette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .contentShape(Capsule())
                .kinroxGlass(
                    in: Capsule(), tint: isOn ? Palette.ember.opacity(0.18) : nil, interactive: true
                )
        }
        .buttonStyle(.plain)
    }
}
