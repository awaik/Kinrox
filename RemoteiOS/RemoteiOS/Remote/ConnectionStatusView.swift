import SwiftUI

struct ConnectionStatusView: View {
    let store: RemoteAppModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        if !store.controlsEnabled {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if isWaiting {
                        ProgressView().tint(Palette.ember)
                    } else {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Palette.flame)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(KinroxFont.bodyStrong)
                        Text(detail).font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
                if store.connectionState == .needsPairing {
                    Button(L10n.text("Connect via Code")) { store.beginPairing() }
                } else if store.connectionState == .failed || store.connectionState == .incompatible
                {
                    Button(L10n.text("Retry")) { store.retryConnection() }
                }
                if store.discoveryStatus == .permissionDenied {
                    Button(L10n.text("Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
                if !isWaiting { Button(L10n.text("To Players List")) { store.returnToPlayers() } }
            }
            .foregroundStyle(Palette.textPrimary).padding(18).frame(
                maxWidth: .infinity, alignment: .leading
            )
            .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.hairline))
        }
    }
    private var isWaiting: Bool {
        [.connecting, .handshaking, .reconnecting, .connected].contains(store.connectionState)
    }
    private var title: String {
        switch store.connectionState {
        case .reconnecting: L10n.format("No connection to “%@”", store.selected?.name ?? "Mac")
        case .connecting, .handshaking, .connected: L10n.text("Connecting to Mac…")
        case .incompatible: L10n.text("Compatible Kinrox version required")
        case .needsPairing: L10n.text("Connect Mac again")
        default: L10n.text("Failed to connect")
        }
    }
    private var detail: String {
        if store.connectionState == .reconnecting {
            return
                L10n.format(
                    "Reconnecting… attempt %@, delay %@ s", store.retryAttempt.formatted(),
                    store.nextRetryDelay.formatted())
        }
        return store.failureMessage ?? L10n.text("Waiting for player state.")
    }
}
