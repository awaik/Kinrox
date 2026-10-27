import SwiftUI

/// Figma 14:313. In M4 the only available tab is Remote; General has no settings yet.
struct RemoteSettingsView: View {
    @Bindable var remote: RemoteServer

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(systemName: "iphone").font(.system(size: 22))
                Text(L10n.text("Remote")).font(KinroxFont.caption)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 10))
            .padding(.vertical, 14)
            Divider().overlay(Palette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    serverCard
                    Text(L10n.text("Paired Remotes")).overlineStyle().padding(.top, 8)
                    VStack(spacing: 0) {
                        if remote.devices.isEmpty {
                            Text(
                                L10n.text(
                                    "No paired remotes yet. Connect iPhone using the code on your Mac screen."
                                )
                            )
                            .font(KinroxFont.body).foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        }
                        ForEach(remote.devices) { device in
                            if device.id != remote.devices.first?.id { Divider() }
                            deviceRow(device)
                        }
                    }
                    .background(Palette.glass, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
                    Label(
                        L10n.text(
                            "Local network only. Commands and tokens are encrypted. Forgotten remotes will require a new code."
                        ),
                        systemImage: "lock"
                    )
                    .font(KinroxFont.caption).foregroundStyle(Palette.textTertiary)
                }
                .padding(32)
            }
        }
        .frame(width: 720, height: 510)
        .foregroundStyle(Palette.textPrimary)
        .background(Palette.elevated)
        .preferredColorScheme(.dark)
        .alert(
            L10n.text("Remote"),
            isPresented: Binding(
                get: { remote.errorMessage != nil },
                set: { if !$0 { remote.errorMessage = nil } })
        ) {
            Button(L10n.text("Dismiss")) { remote.errorMessage = nil }
        } message: {
            Text(remote.errorMessage ?? "")
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { remote.isEnabled }, set: { remote.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Allow Control from iPhone")).font(KinroxFont.bodyStrong)
                    Text(
                        L10n.format(
                            "Kinrox appears as “%@”. Connect new remotes using the code on this screen.",
                            remote.serverName)
                    )
                    .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            .toggleStyle(.switch).tint(Palette.ember).padding(18)
            .accessibilityLabel(L10n.text("Allow Control from iPhone"))
            .accessibilityHint(L10n.text("New remote connects via code from Mac screen"))
            Divider()
            HStack {
                RemoteStatusView(text: remote.statusText, online: remote.isOnline)
                Spacer()
                if case .failed = remote.state {
                    Button(L10n.text("Retry")) { remote.retry() }.tint(Palette.flame)
                }
            }.padding(12)
            if case .waiting = remote.state {
                Text(
                    L10n.text(
                        "Check your network connection and Kinrox permissions in System Settings → Privacy & Security → Local Network."
                    )
                )
                .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                .padding([.horizontal, .bottom], 18)
            }
        }
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone").font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(KinroxFont.bodyStrong).lineLimit(1)
                HStack(spacing: 6) {
                    if remote.connectedDevices[device.id] != nil {
                        Circle().fill(Palette.online).frame(width: 7, height: 7)
                    }
                    Text(
                        L10n.format(
                            "Paired %@", device.pairedAt.formatted(.dateTime.day().month(.wide)))
                            + (remote.connectedDevices[device.id] != nil
                                ? " · " + L10n.text("Online") : "")
                    )
                    .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Button(L10n.text("Forget")) { remote.forget(device.id) }
                .font(KinroxFont.caption).foregroundStyle(Palette.flame)
                .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 7)
                .background(Palette.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline))
                .accessibilityLabel(L10n.format("Forget %@", device.name))
        }.padding(14)
    }
}
