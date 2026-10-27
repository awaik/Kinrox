import SwiftUI

/// Position scrubber: elapsed on left, remaining on right, hover tooltip.
/// Seek performs on release; during drag shows target position.
struct Scrubber: View {
    let model: PlayerViewModel
    let overlay: OverlayController
    @State private var dragFraction: Double?
    @State private var pendingTarget: Double?
    @State private var hoverFraction: Double?

    private var duration: Double { model.duration }

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        let shown = pendingTarget ?? model.position
        return min(1, max(0, shown / duration))
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(TimeFormat.elapsed(fraction * duration, duration: duration))
                .font(KinroxFont.time)
                .foregroundStyle(Palette.textPrimary)
                .frame(minWidth: 52, alignment: .leading)
            GeometryReader { geometry in
                track(width: geometry.size.width)
            }
            .frame(height: 16)
            Text(TimeFormat.remaining(position: fraction * duration, duration: duration))
                .font(KinroxFont.time)
                .foregroundStyle(Palette.textSecondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .onChange(of: model.position) { _, position in
            // Hold target position until mpv confirms seek.
            if let target = pendingTarget, abs(position - target) < 1.5 { pendingTarget = nil }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Position"))
        .accessibilityValue(TimeFormat.elapsed(model.position, duration: duration))
        .accessibilityAdjustableAction { direction in
            model.seek(by: direction == .increment ? 5 : -5)
        }
    }

    private func track(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Palette.glassStrong).frame(height: 4)
            Capsule().fill(Palette.emberGradient).frame(width: max(4, width * fraction), height: 4)
            if let hoverFraction, dragFraction == nil {
                Capsule().fill(Palette.textSecondary)
                    .frame(width: 2, height: 10)
                    .offset(x: width * hoverFraction - 1)
            }
            Circle()
                .fill(Palette.textPrimary)
                .frame(width: 14, height: 14)
                .emberGlow(radius: 8, opacity: 0.6, y: 0)
                .scaleEffect(dragFraction == nil ? 1 : 1.25)
                .offset(x: width * fraction - 7)
        }
        .frame(width: width, height: 16)
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            if let shown = dragFraction ?? hoverFraction, duration > 0 {
                Text(TimeFormat.elapsed(shown * duration, duration: duration))
                    .font(KinroxFont.time)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: Capsule())
                    .kinroxGlass(in: Capsule())
                    .fixedSize()
                    .position(x: width * shown, y: -24)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverFraction = clamp(point.x / width)
            case .ended: hoverFraction = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    overlay.set(.scrubbing, active: true)
                    dragFraction = clamp(value.location.x / width)
                }
                .onEnded { value in
                    let target = clamp(value.location.x / width) * duration
                    pendingTarget = target
                    dragFraction = nil
                    overlay.set(.scrubbing, active: false)
                    model.seek(to: target)
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if pendingTarget == target { pendingTarget = nil }
                    }
                }
        )
        .animation(.easeOut(duration: 0.12), value: dragFraction == nil)
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }
}
