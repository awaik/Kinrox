import SwiftUI

struct DiscoveryStatusView: View {
    let store: RemoteAppModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 16) {
            switch store.discoveryStatus {
            case .searching, .ready: ScanningIndicator()
            case .hints:
                status(L10n.text("Cannot find Kinrox on network"), icon: "wifi")
                Text(
                    L10n.text(
                        "Are Mac and iPhone on the same Wi-Fi network? Is Kinrox running? Is local network access granted?"
                    )
                )
                Button(L10n.text("Retry Discovery")) { store.retryDiscovery() }
            case .permissionDenied:
                status(L10n.text("Allow Local Network Access"), icon: "network.slash")
                Text(L10n.text("Open iPhone Settings → Kinrox → Local Network and enable access."))
                Button(L10n.text("Open Settings")) { openSettings() }
                Button(L10n.text("Check Again")) { store.retryDiscovery() }
            case .noNetwork:
                status(L10n.text("No Local Network Connection"), icon: "wifi.slash")
                Text(L10n.text("Connect iPhone to the same Wi-Fi network as the Mac."))
                Button(L10n.text("Retry Discovery")) { store.retryDiscovery() }
            case .transportError:
                status(L10n.text("Failed to start discovery"), icon: "exclamationmark.triangle")
                Text(L10n.text("A network error occurred. Check connection and retry discovery."))
                Button(L10n.text("Retry")) { store.retryDiscovery() }
            }
        }
        .font(KinroxFont.body).foregroundStyle(Palette.textSecondary)
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
    }
    private func status(_ title: String, icon: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(Palette.flame)
            Text(title).font(KinroxFont.titleLarge()).foregroundStyle(Palette.textPrimary)
        }
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
