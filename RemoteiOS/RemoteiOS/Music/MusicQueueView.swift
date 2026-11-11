import RemoteProtocol
import SwiftUI

struct MusicQueueView: View {
    @Bindable var store: RemoteAppModel
    @State private var detailTrack: RemoteMusicTrack?
    var body: some View {
        List {
            Text(L10n.format("%@ tracks", (store.state.music?.queueCount ?? 0).formatted()))
                .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if store.similarActive {
                MusicSimilarBanner(store: store, offersNotInterested: false)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            section(.current, title: L10n.text("Now Playing"))
            section(.manual, title: L10n.text("Added manually"))
            section(
                .source,
                title: store.similarActive ? L10n.text("Similar") : L10n.text("Source list"))
            if store.queueLoading { ProgressView().listRowBackground(Color.clear) }
            if let offset = store.queueNextOffset {
                Color.clear.frame(height: 1).listRowBackground(Color.clear)
                    .sheet(
                        isPresented: Binding(
                            get: { detailTrack != nil }, set: { if !$0 { detailTrack = nil } })
                    ) {
                        if let track = detailTrack { MusicTrackDetails(track: track) }
                    }
                    .onAppear { if !store.queueLoading { store.requestMusicQueue(offset: offset) } }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Palette.canvas)
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle(L10n.text("Queue")).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SpotifyAttribution() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.send(.setShuffle(shuffle: store.state.music?.shuffle != true))
                } label: {
                    Image(systemName: "shuffle").foregroundStyle(
                        store.state.music?.shuffle == true ? Palette.ember : Palette.flame)
                }.disabled(!store.controlsEnabled || !store.musicAllows("toggling_shuffle"))
                    .accessibilityLabel(L10n.text("Shuffle"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack {
                if let feedback = store.similarFeedback {
                    MusicSimilarFeedbackView(store: store, feedback: feedback).padding(
                        .horizontal, 16)
                } else if let feedback = store.state.music?.favoriteFeedback {
                    SpotifyFavoriteFeedback(liked: feedback.liked)
                }
                Text(L10n.text("Swipe left to remove · hold to reorder"))
                    .font(.system(size: 13)).foregroundStyle(Palette.textTertiary).padding(12)
                    .frame(maxWidth: .infinity).background(Palette.canvas)
            }
        }
        .sheet(isPresented: $store.showsLikeOptions, onDismiss: { store.likeOptionsTrackID = nil })
        { MusicLikeSheet(store: store) }
        .sheet(
            isPresented: Binding(get: { detailTrack != nil }, set: { if !$0 { detailTrack = nil } })
        ) {
            if let track = detailTrack { MusicTrackDetails(track: track) }
        }
        .onAppear {
            store.showsMusicQueue = true
            store.requestMusicQueue()
        }
        .onDisappear { store.showsMusicQueue = false }
    }

    @ViewBuilder
    private func section(_ section: RemoteQueueItem.Section, title: String) -> some View {
        let items = store.musicQueue.filter { $0.section == section }
        if !items.isEmpty {
            Group {
                Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(section == .current ? Palette.flame : Palette.textTertiary)
                    .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items) { item in
                    if section == .current {
                        row(item)
                    } else {
                        row(item)
                            .draggable(item.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let text = ids.first, let id = UUID(uuidString: text),
                                    id != item.id
                                else { return false }
                                store.send(.queueMove(itemId: id, beforeId: item.id))
                                return true
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.send(.queueRemove(itemId: item.id))
                                } label: {
                                    Label(
                                        L10n.text("Remove from queue"), systemImage: "minus.circle")
                                }
                            }
                            .accessibilityAction(named: L10n.text("Remove from queue")) {
                                store.send(.queueRemove(itemId: item.id))
                            }
                            .modifier(
                                SimilarRowActions(
                                    store: store, track: item.track,
                                    enabled: section == .source && store.similarActive))
                    }
                }
            }
        }
    }
    private func row(_ item: RemoteQueueItem) -> some View {
        HStack(spacing: 12) {
            if item.section == .current {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach([8.0, 14, 10], id: \.self) { height in
                        Rectangle().fill(Palette.ember).frame(width: 3, height: height)
                    }
                }.accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if item.track.explicit == true { SpotifyExplicitBadge() }
                    Text(item.track.title).font(
                        .system(size: 17, weight: item.section == .current ? .semibold : .regular)
                    )
                    .foregroundStyle(item.section == .current ? Palette.flame : Palette.textPrimary)
                }
                Text(item.track.artists.joined(separator: ", ") + " · " + item.track.album)
                    .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
            }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture { detailTrack = item.track }
                .accessibilityAction(named: L10n.text("Track details")) { detailTrack = item.track }
            Text(TimeFormat.string(item.track.duration)).font(KinroxFont.monoDigits(13))
                .foregroundStyle(Palette.textTertiary)
            Button {
                store.toggleMusicLike(trackId: item.track.id, currentlyLiked: item.liked)
            } label: {
                RemoteMusicIcon(name: item.liked ? "SpotifySaved" : "SpotifyAdd", size: 16)
                    .foregroundStyle(item.liked ? Palette.ember : Palette.textTertiary).frame(
                        width: 44, height: 44)
            }.buttonStyle(.borderless).accessibilityLabel(
                L10n.format("Favorite %@", item.track.title)
            )
            .accessibilityValue(item.liked ? L10n.text("On") : L10n.text("Off"))
        }.padding(.leading, 16).padding(.trailing, 4).frame(height: 60)
            .background(
                item.section == .current ? Palette.glass : .clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}

/// Not interested on pending similar rows: leading swipe and long-press menu.
private struct SimilarRowActions: ViewModifier {
    @Bindable var store: RemoteAppModel
    let track: RemoteMusicTrack
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .swipeActions(edge: .leading) {
                    Button {
                        store.hideFromSimilar(track, scope: .track)
                    } label: {
                        Label(
                            L10n.text("Not interested in this track"),
                            systemImage: "hand.thumbsdown")
                    }.tint(.gray)
                }
                .contextMenu { MusicNotInterestedItems(store: store, track: track) }
                .accessibilityAction(named: L10n.text("Not interested in this track")) {
                    store.hideFromSimilar(track, scope: .track)
                }
        } else {
            content
        }
    }
}
