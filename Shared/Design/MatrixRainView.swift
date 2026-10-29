import SwiftUI

/// Figma page 07: independent downward streams, fading tails and bright leading glyphs.
/// The same procedural field is used as the iPhone card's static preview.
struct MatrixRainView: View {
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private static let glyphs = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン０１２３４５６７８９")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !runsAnimation)) { timeline in
            // Capture the changing timeline value in Canvas so SwiftUI invalidates
            // its drawing every frame, even when no other view state changes.
            let elapsed = runsAnimation ? max(0, timeline.date.timeIntervalSince(startedAt)) : 0
            Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                draw(in: &context, size: size, elapsed: elapsed)
            }
        }
        .background(.black)
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    // The player lives in an AppKit NSHostingView, outside a SwiftUI Scene.
    // Its scenePhase does not track the window. Keep falling on a second display
    // or while the remote is in use; removing this view stops its timeline.
    private var runsAnimation: Bool { animated && !reduceMotion }

    private func draw(in context: inout GraphicsContext, size: CGSize, elapsed: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        guard size.width > 0, size.height > 0 else { return }
        let cell = max(2, size.width / 80)
        let line = cell * 1.25
        let rows = Int(ceil(size.height / line))
        let glyphs = Self.glyphs.map {
            context.resolve(Text(String($0)).font(.system(size: cell, design: .monospaced)))
        }
        for column in 0..<80 {
            let length = 14 + (column * 11) % 23
            let cycle = Double(rows + length + 12)
            let speed = 5.0 + Double((column * 13) % 17) / 2
            let phase = Double((column * 19 + (column / 3) * 7) % Int(cycle))
            let head = (phase + elapsed * speed).truncatingRemainder(dividingBy: cycle)
            for tail in 0..<length {
                let row = head - Double(tail)
                guard row >= -1, row < Double(rows + 1) else { continue }
                let index =
                    (column * 23 + Int(floor(head)) * 17 + tail * 7 + Int(elapsed * 6))
                    % glyphs.count
                var glyph = glyphs[index]
                glyph.shading = .color(tail == 0 ? Palette.matrixHead : Palette.matrixCode)
                var layer = context
                layer.opacity =
                    tail == 0
                    ? 1
                    : pow(1 - Double(tail) / Double(length), 1.35)
                        * (0.54 + Double(column % 4) * 0.14)
                layer.draw(
                    glyph, at: CGPoint(x: Double(column) * cell, y: row * line), anchor: .topLeading
                )
            }
        }
    }
}
