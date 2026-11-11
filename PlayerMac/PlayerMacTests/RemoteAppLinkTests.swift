import AppKit
import CoreImage
import Testing

@testable import Kinrox

@MainActor
struct RemoteAppLinkTests {
    @Test func qrCodeOpensTheRemoteAppStorePage() throws {
        #expect(RemoteAppLink.url.absoluteString == "https://apps.apple.com/app/id6827926471")
        let image = try #require(RemoteAppLink.makeQRImage(for: RemoteAppLink.url))
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        #expect(cgImage.width >= 300)  // Rendered large, so views never upscale it.
        let scaled = CIImage(cgImage: cgImage)
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode, context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: scaled).compactMap { $0 as? CIQRCodeFeature }
        #expect(codes.first?.messageString == RemoteAppLink.url.absoluteString)
    }
}
