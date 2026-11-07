import SwiftUI

struct MusicView: View {
    @Bindable var session: PlayerSession
    @Bindable var model: MusicViewModel

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1100
            VStack(spacing: 0) {
                MusicTitleBar(session: session, model: model, width: geometry.size.width)
                DeckView(model: model, compact: compact, width: geometry.size.width)
                HStack(spacing: 0) {
                    if !compact {
                        SourceColumn(model: model).frame(width: 268)
                        divider
                    }
                    VStack(spacing: 0) {
                        if compact { MusicSourcePicker(model: model) }
                        Group {
                            if model.selection.source == .similar {
                                DiscoveryWorkspaceView(model: model)
                            } else if model.selection.source == .albums && model.isAlbumsOverview {
                                AlbumsWorkspaceView(model: model)
                            } else if model.isQueue {
                                QueueView(model: model)
                            } else {
                                TrackTable(model: model)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    divider
                    CompactQueueColumn(model: model).frame(width: compact ? 280 : 320)
                }.frame(maxHeight: .infinity)
                MusicStatusBar(model: model)
            }.background(Palette.canvas).foregroundStyle(Palette.textPrimary)
                .background(MusicKeyboard(model: model, enabled: session.musicShortcutsAllowed))
        }.preferredColorScheme(.dark).ignoresSafeArea()
    }

    private var divider: some View { Rectangle().fill(Palette.hairline).frame(width: 1) }
}

struct MusicTitleBar: View {
    @Bindable var session: PlayerSession
    @Bindable var model: MusicViewModel
    let width: CGFloat
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 16) {
            Text("Kinrox").font(.system(size: 17, weight: .semibold)).padding(.leading, 88)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                TextField(L10n.text("Artist, album or track"), text: $model.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onChange(of: model.query) { _, _ in model.search() }
                if !model.query.isEmpty {
                    Button {
                        model.leaveSearch()
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear search"))
                } else {
                    Text("⌘F").font(.system(size: 10))
                }
            }.font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 10).frame(
                    width: min(300, max(140, width / 2 - 370)), height: 30
                )
                .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.strokeGlass))
            Link(destination: spotifyURL) { SpotifyAttribution() }.buttonStyle(.plain)
            Button {
                openSettings()
            } label: {
                Text(
                    (model.isDemo
                        ? L10n.text("Demo")
                        : (model.accountName ?? L10n.text("Connect Spotify")))
                ).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(Palette.textSecondary).padding(.horizontal, 12).frame(
                        height: 30
                    )
                    .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8)).frame(
                        maxWidth: 110)
            }.buttonStyle(.plain)
        }.padding(.trailing, 12).frame(height: 52).background(Palette.elevated)
            .overlay { AppModePicker(session: session).frame(width: 198) }
            .onChange(of: model.searchRequested) { _, requested in
                if requested {
                    searchFocused = true
                    model.searchRequested = false
                }
            }
            .onChange(of: searchFocused) { _, focused in model.isSearching = focused }
            .onExitCommand {
                model.leaveSearch()
                searchFocused = false
            }
    }

    private var spotifyURL: URL {
        if let id = model.album?.id, !model.isDemo {
            return URL(string: "https://open.spotify.com/album/" + id)!
        }
        if let id = model.currentTrack?.id, !model.isDemo {
            return URL(string: "https://open.spotify.com/track/" + id)!
        }
        return URL(string: "https://open.spotify.com/")!
    }
}

struct MusicStatusBar: View {
    @Bindable var model: MusicViewModel
    var body: some View {
        HStack(spacing: 12) {
            if let message = model.statusMessage,
                model.retryChange != nil || model.retryPlaylist != nil
            {
                Text(message)
                Button(L10n.text("Retry"), action: model.retry).disabled(
                    !model.canMutate
                ).buttonStyle(.plain).foregroundStyle(
                    Palette.flame)
            } else if let liked = model.favoriteFeedbackLiked {
                SpotifyFavoriteFeedback(liked: liked)
            } else {
                Text(L10n.text("Space: pause · Enter: play · L: favorite · ⌘F: search · ⌘Z: undo"))
            }
            Spacer(minLength: 0)
            if model.isDemo { Text(L10n.text("Demo · No audio")) }
            Text(L10n.format("%@ tracks", model.library.likedTrackIDs.count.formatted()))
                .monospacedDigit()
        }.font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 20).frame(height: 28).background(Palette.elevated)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}
