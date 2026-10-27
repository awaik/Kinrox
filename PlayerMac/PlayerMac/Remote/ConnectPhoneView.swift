import SwiftUI

/// Sheet Figma 14:378; replaced by PIN view upon pairing request.
struct ConnectPhoneView: View {
    let remote: RemoteServer
    let done: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.45)).background(.ultraThinMaterial).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "iphone").font(.system(size: 28, weight: .semibold))
                        .frame(width: 60, height: 60)
                        .background(Palette.emberDiagonal, in: RoundedRectangle(cornerRadius: 20))
                        .emberGlow()
                    Text(L10n.text("Connect iPhone")).font(KinroxFont.titleLarge()).padding(
                        .top, 18)
                    Text(
                        L10n.text(
                            "Remote works over the same Wi-Fi network, without accounts or cloud.")
                    )
                    .font(KinroxFont.body).foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 14) {
                        step(1, L10n.text("Open Kinrox on iPhone"))
                        step(2, L10n.format("Select “%@” in the players list", remote.serverName))
                        step(3, L10n.text("Enter the code shown here"))
                    }.padding(.vertical, 22)
                    if remote.isOnline {
                        RemoteStatusView(
                            text: remote.connectedDevices.isEmpty
                                ? L10n.text("Waiting for iPhone on the network…")
                                : L10n.text("Remote connected"), online: true,
                            waiting: remote.connectedDevices.isEmpty)
                    } else if !remote.isEnabled {
                        RemotePillButton(title: L10n.text("Enable Remote")) {
                            remote.setEnabled(true)
                        }
                    } else {
                        Text(remote.statusText).font(KinroxFont.caption).foregroundStyle(
                            Palette.textSecondary)
                        Button(L10n.text("Open Settings")) {
                            openSettings()
                            done()
                        }.padding(.top, 8)
                    }
                    Button(action: done) {
                        Text(L10n.text("Done")).font(KinroxFont.bodyStrong).frame(
                            maxWidth: .infinity
                        )
                        .padding(.vertical, 12).background(Palette.glass, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline))
                    }
                    .buttonStyle(PressScaleStyle()).keyboardShortcut(.cancelAction).padding(
                        .top, 22)
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(32)
                .frame(width: 460)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 32))
                .kinroxGlass(in: RoundedRectangle(cornerRadius: 32))
                .padding(28)
                .frame(maxWidth: .infinity)
            }.scrollIndicators(.never)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 14) {
            Text("\(number)").font(KinroxFont.caption).frame(width: 28, height: 28)
                .background(Palette.glassStrong, in: Circle())
            Text(text).font(KinroxFont.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}
