import SwiftUI

extension RemoteServer {
    var isOnline: Bool { if case .ready = state { true } else { false } }

    var statusText: String {
        guard isEnabled else { return L10n.text("Remote is off") }
        switch state {
        case .ready:
            return connectedDevices.isEmpty
                ? L10n.text("Online · waiting for connections")
                : L10n.format("Online · connected: %@", connectedDevices.count.formatted())
        case .starting: return L10n.text("Connecting to network…")
        case .waiting: return L10n.text("Waiting for local network access")
        case .failed: return L10n.text("Failed to enable remote")
        case .stopped: return L10n.text("Remote temporarily unavailable")
        }
    }

    var welcomeStatus: String {
        guard isOnline else { return statusText }
        let count = devices.count
        return L10n.format("Remote is on · devices: %@", count.formatted())
    }

    var controllerText: String? {
        let names = connectedDevices.values.sorted()
        guard !names.isEmpty else { return nil }
        return L10n.format("Controlled by %@", names.joined(separator: ", "))
    }
}

struct RemoteStatusView: View {
    let text: String
    let online: Bool
    var waiting = false

    var body: some View {
        HStack(spacing: 8) {
            if waiting {
                ProgressView().controlSize(.small).tint(Palette.ember)
            } else {
                Circle().fill(online ? Palette.online : Palette.textTertiary).frame(
                    width: 8, height: 8)
            }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(KinroxFont.caption)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Palette.glass, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .accessibilityElement(children: .combine)
    }
}

struct RemotePillButton: View {
    let title: String
    var icon: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(KinroxFont.bodyStrong)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Palette.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}
