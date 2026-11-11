import SwiftUI

/// Navigation belongs to model: delayed callback cannot revert previous screen.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var host = RemoteAppHost.shared
    private var store: RemoteAppModel { host.store }

    var body: some View {
        NavigationStack(
            path: Binding(
                get: { store.screen == .players ? [] : [store.screen] },
                set: { if $0.isEmpty { store.returnToPlayers() } })
        ) {
            PlayersView(store: store, switchMode: switchMode)
                .navigationDestination(for: RemoteAppModel.Screen.self) { screen in
                    switch screen {
                    case .players: EmptyView()
                    case .pairing: PairingView(store: store)
                    case .remote:
                        if store.state.source == .music, store.supportsMusic {
                            MusicRemoteView(store: store, switchMode: switchMode)
                        } else {
                            RemoteView(store: store, switchMode: switchMode)
                        }
                    }
                }
        }
        .tint(Palette.ember)
        .task {
            guard NSClassFromString("XCTestCase") == nil else { return }
            guard UIApplication.shared.applicationState != .background else { return }
            // A window opened after a background Lock Screen launch takes over its session.
            store.enterForeground()
            openDebugScreen()
        }
        .onChange(of: scenePhase) { _, phase in
            guard NSClassFromString("XCTestCase") == nil else { return }
            if phase == .background { store.enterBackground() }
            if phase == .active { store.enterForeground() }
        }
    }

    private func switchMode() { host.switchMode() }

    private func openDebugScreen() {
        #if DEBUG
            guard store.isDemo, store.players.count > 1 else { return }
            switch UserDefaults.standard.string(forKey: "KinroxScreen") {
            case "pairing": store.select(store.players[1])
            case "remote", "recents": store.select(store.players[0])
            case "music", "music-queue", "music-like", "music-similar", "music-similar-queue":
                store.select(store.players[0])
                store.enableMusicDemo()
            default: break
            }
        #endif
    }
}

/// Dark screen background with amber glow on top (as in designs).
struct EmberBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            Palette.base
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Palette.ember.opacity(0.28), Palette.ember.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 260)
                )
                .frame(width: 520, height: 360)
                .blur(radius: 40)
                .offset(y: -200)
        }
        .ignoresSafeArea()
    }
}

/// Round glass icon button (Figma: Control/Icon Button).
struct GlassIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 17
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.opacity(isEnabled ? 1 : 0.35))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .kinroxGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
