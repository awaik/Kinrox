import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// App Store page of Kinrox Remote for iPhone (Figma `15 · Mac — Get the iPhone remote`).
/// The QR code is generated locally; showing it makes no network request.
enum RemoteAppLink {
    static let url = URL(string: "https://apps.apple.com/app/id6827926471")!

    /// Rendered large with hard edges, so scaling it down in views stays sharp.
    @MainActor static let qrImage: NSImage? = makeQRImage(for: url)

    static func open() { NSWorkspace.shared.open(url) }

    static func makeQRImage(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        // Nearest sampling keeps module edges crisp; linear scaling blurs them.
        guard
            let output = filter.outputImage?.samplingNearest()
                .transformed(by: CGAffineTransform(scaleX: 16, y: 16)),
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}

/// Dark modules on a light tile: phone cameras need the contrast.
struct RemoteAppQRCode: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = RemoteAppLink.qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit()
                    .foregroundStyle(.black.opacity(0.6))
            }
        }
        .padding(size * 0.08)
        .frame(width: size, height: size)
        .background(.white, in: RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
        .accessibilityLabel(L10n.text("QR code for Kinrox Remote in the App Store"))
    }
}

/// Figma `237:309`: opens the App Store page in the default browser.
struct OpenRemoteInAppStoreButton: View {
    var body: some View {
        Button(action: RemoteAppLink.open) {
            HStack(spacing: 4) {
                Text(L10n.text("Open in App Store"))
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
            }
            .font(KinroxFont.bodyStrong)
            .foregroundStyle(Palette.flame)
        }
        .buttonStyle(.plain)
        .help(RemoteAppLink.url.absoluteString)
    }
}

/// Figma `237:311` (Connect iPhone sheet) and `237:321` (Settings → Remote).
struct GetRemoteCard: View {
    enum Style { case sheet, settings }
    let style: Style

    var body: some View {
        HStack(alignment: style == .sheet ? .center : .top, spacing: 16) {
            RemoteAppQRCode(size: style == .sheet ? 132 : 88)
            VStack(alignment: .leading, spacing: 6) {
                Text(style == .sheet ? L10n.text("No remote yet?") : L10n.text("iPhone remote"))
                    .font(style == .sheet ? KinroxFont.title : KinroxFont.bodyStrong)
                Text(
                    style == .sheet
                        ? L10n.text(
                            "Scan with your iPhone camera to install Kinrox Remote from the App Store. It’s free."
                        )
                        : L10n.text(
                            "Install Kinrox Remote on iPhone to control playback from the couch.")
                )
                .font(style == .sheet ? KinroxFont.body : KinroxFont.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                OpenRemoteInAppStoreButton().padding(.top, style == .sheet ? 6 : 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
    }
}
