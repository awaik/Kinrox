import AppKit
import SwiftUI
import Testing

@testable import Kinrox

@Suite("Soloist native setup layout", .serialized)
@MainActor
struct SoloistLayoutTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_UI_ROOT"] != nil))
    func approvedStatesRenderAtSettingsWidth() throws {
        let path = try #require(ProcessInfo.processInfo.environment["KINROX_SOLOIST_UI_ROOT"])
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, state): (String, MusicEngineAvailability) in [
            ("key", .needsKey), ("pairing", .needsPairing), ("ready", .ready),
            ("download", .downloading), ("expired", .expired),
            ("starting", .starting), ("reconnecting", .reconnecting),
            ("external-takeover", .externalTakeover),
            (
                "wrong-account",
                .failed(L10n.text("A different Spotify account is paired. Pair again."))
            ),
        ] {
            let setup = SoloistSetup()
            setup.observeRuntime(state)
            let host = NSHostingView(
                rootView:
                    SoloistSettingsSection(setup: setup)
                    .frame(width: 560).fixedSize(horizontal: false, vertical: true)
                    .background(Palette.elevated).preferredColorScheme(.dark))
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.width == 560)
            #expect(host.frame.height > 60 && host.frame.height < 1000)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: root.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
        }
    }
}
