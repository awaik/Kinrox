import SwiftUI

struct HomeTitlebarControls: View {
    @Bindable var session: PlayerSession
    let budget: CGFloat
    let iconOnly: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if iconOnly || budget < 160 {
                Button {
                    if session.isHomeSearchShown {
                        session.leaveHomeSearch()
                    } else {
                        session.focusHomeSearch()
                    }
                } label: {
                    Image(systemName: "magnifyingglass").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Search Library"))
                remoteIndicator(compact: true)
            } else {
                HomeSearchField(session: session, inline: false)
                    .frame(width: min(296, budget - (budget >= 360 ? 118 : 0)))
                if budget >= 360 { remoteIndicator(compact: false) }
            }
        }
    }

    @ViewBuilder
    private func remoteIndicator(compact: Bool) -> some View {
        if let remote = session.remote {
            Button(action: connect) {
                HStack(spacing: 6) {
                    Circle().fill(remote.isOnline ? Palette.online : Palette.textTertiary)
                        .frame(width: 6, height: 6)
                    if compact {
                        Image(systemName: "iphone")
                    } else {
                        Text(L10n.text("Remote")).lineLimit(1)
                    }
                }
                .font(KinroxFont.caption)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Palette.glass, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Connect iPhone"))
            .accessibilityLabel(L10n.text("Connect iPhone"))
        }
    }
}

struct HomeSearchField: View {
    @Bindable var session: PlayerSession
    let inline: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
            TextField(
                L10n.text("Search movies, series, tracks, and genres"),
                text: $session.homeFilter.query
            )
            .textFieldStyle(.plain)
            .focused($focused)
            .accessibilityIdentifier("home-search-field")
            if !session.homeFilter.query.isEmpty {
                Button {
                    session.homeFilter.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Clear Search"))
            }
            if !inline { Text("⌘F").foregroundStyle(Palette.textTertiary) }
        }
        .font(KinroxFont.caption)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .onAppear {
            if inline { focused = session.isHomeSearchShown }
        }
        .onChange(of: session.searchFocusRequest) { _, _ in focused = true }
        .onChange(of: focused) { _, focus in session.isHomeSearchFocused = focus }
        .onChange(of: session.isHomeSearchFocused) { _, focus in if !focus { focused = false } }
        .onDisappear { if focused { session.isHomeSearchFocused = false } }
    }
}
