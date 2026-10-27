import SwiftUI

/// Screen 1 Players: Mac on local network (Figma: iPhone / Players).
struct PlayersView: View {
    let store: RemoteAppModel
    let switchMode: () -> Void
    @State private var showsSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    GlassIconButton(systemName: "slider.horizontal.3", label: L10n.text("Settings"))
                    {
                        showsSettings = true
                    }
                }
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Kinrox")
                            .font(KinroxFont.display(38))
                            .foregroundStyle(Palette.textPrimary)
                        if store.isDemo { DemoBadge() }
                    }
                    Text(L10n.text("Select Mac to control"))
                        .font(KinroxFont.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.top, 8)
                Text(L10n.text("On this network")).overlineStyle()
                    .padding(.top, 34)
                    .padding(.bottom, 10)
                VStack(spacing: 10) {
                    ForEach(store.players) { player in
                        DeviceRow(player: player) { store.select(player) }
                            .contextMenu {
                                Button(L10n.text("Forget this Mac"), role: .destructive) {
                                    store.selected = SavedMac(id: player.id, name: player.name)
                                    store.forgetSelected()
                                }
                            }
                    }
                }
                Spacer(minLength: 24)
                if !store.isDemo { DiscoveryStatusView(store: store) }
                if let message = store.failureMessage, store.screen == .players {
                    Text(message).foregroundStyle(Palette.flame).padding(.vertical)
                }
            }
            .padding(.horizontal, 24)
        }
        .background(EmberBackdrop())
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(L10n.text("Players"))
        .sheet(isPresented: $showsSettings) {
            SettingsView(store: store, switchMode: switchMode)
        }
    }
}

/// Explicit label for isolated demo mode.
struct DemoBadge: View {
    var body: some View {
        Text(L10n.text("Demo"))
            .font(KinroxFont.caption)
            .foregroundStyle(Palette.flame)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.ember.opacity(0.15), in: Capsule())
            .accessibilityLabel(L10n.text("Demo mode without Mac connection"))
    }
}

/// Mac row (Figma: `Row/Device`).
struct DeviceRow: View {
    let player: MacPlayer
    let action: () -> Void

    private var isAvailable: Bool { player.status != .unavailable }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(KinroxFont.title)
                        .lineLimit(2)
                        .foregroundStyle(Palette.textPrimary)
                    Text(player.detail)
                        .font(KinroxFont.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(14)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(
                        player.status == .paired ? Palette.ember.opacity(0.55) : Palette.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : 0.4)
        .sensoryFeedback(.selection, trigger: player.status)
    }
}

/// Bonjour discovery radar: pulsating rings around Wi-Fi icon.
struct ScanningIndicator: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(0..<3) { ring in
                    Circle()
                        .stroke(
                            Palette.ember.opacity(0.12 + Double(2 - ring) * 0.12), lineWidth: 1.5
                        )
                        .frame(width: 100 + CGFloat(ring) * 60, height: 100 + CGFloat(ring) * 60)
                        .scaleEffect(pulse ? 1.06 : 0.94)
                        .animation(
                            .easeInOut(duration: 1.6).repeatForever().delay(Double(ring) * 0.25),
                            value: pulse)
                }
                Image(systemName: "wifi")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(Palette.glassStrong, in: Circle())
            }
            .frame(height: 230)
            VStack(spacing: 4) {
                Text(L10n.text("Looking for Kinrox…"))
                    .font(KinroxFont.bodyStrong)
                    .foregroundStyle(Palette.textSecondary)
                Text(L10n.text("Mac and iPhone must be on the same Wi-Fi network"))
                    .font(KinroxFont.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
    }
}
