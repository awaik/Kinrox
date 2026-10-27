import SwiftUI

/// Abstract still placeholder for recent cards.
/// No artwork in v1, appearance selected by filename.
struct StillArtwork: View {
    let seed: Int

    private struct Scene {
        let sky: [Color]
        let sun: Color
        let ridges: [Color]
    }

    private static let scenes: [Scene] = [
        // Ember Dusk
        Scene(
            sky: [rgb(0x1B0F2B), rgb(0x5E1A2E), rgb(0xE8541F), rgb(0xFFB25C)], sun: rgb(0xFFE2B0),
            ridges: [rgb(0x4A1426), rgb(0x2A0F1B), rgb(0x160A10), rgb(0x070407)]),
        // Blue Hour
        Scene(
            sky: [rgb(0x060B1F), rgb(0x14244A), rgb(0x3D5C8F), rgb(0xE9A27A)], sun: rgb(0xFFE9D2),
            ridges: [rgb(0x1C2B4D), rgb(0x121C35), rgb(0x0A1124), rgb(0x04070F)]),
        // Desert Noon
        Scene(
            sky: [rgb(0x2B1A12), rgb(0x8A4A2A), rgb(0xE59A5B), rgb(0xF7D7A6)], sun: rgb(0xFFF4DD),
            ridges: [rgb(0x7A3A22), rgb(0x4D2416), rgb(0x2B140D), rgb(0x120806)]),
    ]

    // Ridges from design, coordinates in fractions of 1600x900 frame.
    private static let ridgePoints: [[(Double, Double)]] = [
        [
            (0, 560), (180, 470), (320, 520), (470, 410), (640, 500), (760, 450), (900, 530),
            (1080, 440), (1260, 520), (1420, 430), (1600, 500),
        ],
        [
            (0, 640), (140, 580), (300, 630), (460, 560), (620, 640), (800, 590), (980, 650),
            (1160, 580), (1340, 640), (1500, 600), (1600, 630),
        ],
        [
            (0, 720), (200, 670), (380, 720), (560, 680), (760, 740), (980, 690), (1180, 745),
            (1380, 700), (1600, 740),
        ],
        [(0, 800), (260, 770), (520, 810), (800, 780), (1080, 820), (1340, 790), (1600, 815)],
    ]

    var body: some View {
        let scene = Self.scenes[abs(seed) % Self.scenes.count]
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: scene.sky[0], location: 0),
                        .init(color: scene.sky[1], location: 0.38),
                        .init(color: scene.sky[2], location: 0.62),
                        .init(color: scene.sky[3], location: 0.72),
                    ], startPoint: .top, endPoint: .bottom)
                RadialGradient(
                    colors: [scene.sun.opacity(0.85), scene.sky[3].opacity(0)],
                    center: UnitPoint(x: 0.65, y: 0.56), startRadius: 0,
                    endRadius: size.width * 0.19)
                ForEach(0..<Self.ridgePoints.count, id: \.self) { index in
                    Ridge(points: Self.ridgePoints[index]).fill(scene.ridges[index])
                }
            }
        }
    }

    private static func rgb(_ value: Int) -> Color {
        Color(
            red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// Deterministic scene index between runs: string hashValue is randomized.
    static func seed(for title: String) -> Int {
        title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}

private struct Ridge: Shape {
    let points: [(Double, Double)]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scaled = points.map {
            CGPoint(
                x: rect.minX + $0.0 / 1600 * rect.width, y: rect.minY + $0.1 / 900 * rect.height)
        }
        guard let first = scaled.first else { return path }
        path.move(to: first)
        for point in scaled.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
