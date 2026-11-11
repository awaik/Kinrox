import RemoteProtocol
import SwiftUI

/// Figma 111:2925: fixed deck semantics, no album browser or artwork.
struct MusicRemoteView: View {
    @Bindable var store: RemoteAppModel
    let switchMode: () -> Void
    @State private var showsSettings = false
    @State private var detailTrack: RemoteMusicTrack?
    private var music: MusicState? { store.state.music }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    header
                    sourceIndicator
                    ConnectionStatusView(store: store)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(spacing: 18) {
                            display(position: store.position)
                            seek(position: store.position)
                        }
                    }
                    if let feedback = store.similarFeedback {
                        MusicSimilarFeedbackView(store: store, feedback: feedback)
                    } else if let feedback = music?.favoriteFeedback {
                        SpotifyFavoriteFeedback(liked: feedback.liked)
                    }
                    transport
                    switches
                    MusicSimilarControl(store: store)
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 16))
                        MusicSlider(
                            value: store.state.volume, range: 0...100, label: L10n.text("Volume"),
                            step: 5, valueKnown: music?.volumeKnown != false
                        ) { store.setVolume($0) }
                        .tint(Palette.textPrimary).disabled(
                            !store.controlsEnabled || !store.musicAllows("volume"))
                        Text(
                            music?.volumeKnown == false ? "—" : Int(store.state.volume).formatted()
                        )
                        .font(KinroxFont.monoDigits(13))
                        .frame(width: 28)
                    }.foregroundStyle(Palette.textSecondary).frame(height: 28)
                    Spacer(minLength: 16)
                    if let status = music?.status ?? store.commandError {
                        Text(status).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                    }
                    Button {
                        store.showsMusicQueue = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "list.bullet")
                            Text(L10n.text("Queue"))
                            Text((music?.queueCount ?? 0).formatted()).monospacedDigit()
                                .foregroundStyle(Palette.textTertiary)
                        }.font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity).frame(
                            height: 52
                        )
                        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
                .frame(minHeight: max(0, geometry.size.height))
            }
        }
        .foregroundStyle(Palette.textPrimary).background(Palette.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $store.showsMusicQueue) { MusicQueueView(store: store) }
        .sheet(isPresented: $store.showsLikeOptions, onDismiss: { store.likeOptionsTrackID = nil })
        { MusicLikeSheet(store: store) }
        .sheet(
            isPresented: Binding(get: { detailTrack != nil }, set: { if !$0 { detailTrack = nil } })
        ) {
            if let track = detailTrack { MusicTrackDetails(track: track) }
        }
        .sheet(isPresented: $showsSettings) { SettingsView(store: store, switchMode: switchMode) }
        .task {
            #if DEBUG
                guard store.isDemo else { return }
                let screen = UserDefaults.standard.string(forKey: "KinroxScreen")
                if screen == "music-similar" || screen == "music-similar-queue" {
                    store.setSimilar(true)
                }
                if screen == "music-queue" || screen == "music-similar-queue" {
                    store.showsMusicQueue = true
                }
                if UserDefaults.standard.string(forKey: "KinroxScreen") == "music-like",
                    let id = music?.track?.id
                {
                    store.likeOptionsTrackID = id
                    store.showsLikeOptions = true
                    store.requestLikeOptions(id)
                }
            #endif
        }
    }

    private var header: some View {
        HStack {
            Button("Kinrox") { store.returnToPlayers() }.font(
                .system(size: 20, weight: .semibold, design: .rounded)
            )
            .accessibilityLabel(L10n.text("Players"))
            Spacer()
            SpotifyAttribution()
            Spacer()
            Button {
                showsSettings = true
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(store.controlsEnabled ? Palette.online : Palette.flame).frame(
                        width: 7, height: 7)
                    Text(store.selected?.name ?? "Mac").font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }.padding(.horizontal, 10).frame(height: 30).background(
                    Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            }.accessibilityLabel(L10n.text("Settings"))
        }.buttonStyle(.plain).frame(height: 44)
    }

    private var sourceIndicator: some View {
        HStack(spacing: 2) {
            Text(L10n.text("Video")).frame(maxWidth: .infinity).foregroundStyle(
                Palette.textSecondary)
            Text(L10n.text("Music")).frame(maxWidth: .infinity).frame(height: 34)
                .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 7))
        }.font(.system(size: 15, weight: .medium)).padding(2).frame(height: 38)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("Music"))
    }

    private func display(position: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RemoteMusicIcon(name: store.state.paused ? "MusicPause" : "MusicPlay", size: 14)
                Text(TimeFormat.string(position)).font(KinroxFont.monoDigits(48)).tracking(-2)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(TimeFormat.remaining(position: position, duration: store.state.duration))
                    .font(KinroxFont.monoDigits(15)).foregroundStyle(Palette.textSecondary)
            }.foregroundStyle(Palette.flame).frame(height: 100)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<34) { index in
                    Rectangle().fill(Palette.ember).frame(
                        width: 6, height: store.state.paused ? 3 : CGFloat(4 + (index * 7) % 23))
                }
            }.frame(height: 26, alignment: .bottom).accessibilityHidden(true)
            Button {
                detailTrack = music?.track
            } label: {
                HStack {
                    if music?.track?.explicit == true { SpotifyExplicitBadge() }
                    Text(music?.track?.title ?? "—").font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle").font(.body)
                }
            }.buttonStyle(.plain).accessibilityLabel(
                Text(L10n.text("Track details")) + Text(": " + (music?.track?.title ?? "")))
            VStack(spacing: 4) {
                field(L10n.text("Artists"), music?.track?.artists.joined(separator: ", ") ?? "—")
                field(
                    L10n.text("Album"),
                    [music?.track?.album, music?.track?.year].compactMap { $0 }.filter {
                        !$0.isEmpty
                    }.joined(separator: " · "))
                Button {
                    detailTrack = music?.nextTrack
                } label: {
                    field(
                        L10n.text("Next track"),
                        music?.nextTrack.map {
                            $0.title + " — " + $0.artists.joined(separator: ", ")
                        }
                            ?? "—")
                }.buttonStyle(.plain)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.black, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline))
            .accessibilityElement(children: .contain)
    }
    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(
                Palette.textTertiary
            ).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 15)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func seek(position: Double) -> some View {
        VStack(spacing: 4) {
            MusicSlider(
                value: position, range: 0...max(1, store.state.duration),
                label: L10n.text("Playback position"), step: 10
            ) { store.seek(to: $0) }
            .tint(Palette.ember).frame(height: 20)
            HStack {
                Text(TimeFormat.string(position))
                Spacer()
                Text(TimeFormat.string(store.state.duration))
            }
            .font(KinroxFont.monoDigits(13)).foregroundStyle(Palette.textSecondary)
        }.disabled(!store.controlsEnabled || !store.state.hasMedia || !store.musicAllows("seeking"))
    }
    private var transport: some View {
        HStack(spacing: 24) {
            transportButton(
                "MusicPrev", L10n.text("Previous track"), size: 68, enabled: store.canPrevious,
                action: store.previous)
            transportButton(
                store.state.paused ? "MusicPlay" : "MusicPause",
                store.state.paused ? L10n.text("Play") : L10n.text("Pause"),
                size: 92,
                enabled: store.controlsEnabled && store.state.hasMedia
                    && store.musicAllows(store.state.paused ? "resuming" : "pausing"),
                action: store.togglePause)
            transportButton(
                "MusicNext", L10n.text("Next track"), size: 68, enabled: store.canNext,
                action: store.next)
        }.frame(maxWidth: .infinity).environment(\.layoutDirection, .leftToRight)
    }
    private func transportButton(
        _ icon: String, _ title: String, size: CGFloat, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RemoteMusicIcon(name: icon, size: size == 92 ? 36 : 26).frame(width: size, height: size)
                .foregroundStyle(size == 92 ? .black : Palette.textPrimary)
                .background(
                    size == 92 ? Palette.ember : Palette.glass,
                    in: RoundedRectangle(cornerRadius: size == 92 ? 28 : 20))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4).accessibilityLabel(
            title)
    }
    private var switches: some View {
        HStack(spacing: 8) {
            RemoteMusicSwitch(title: L10n.text("Shuffle"), on: music?.shuffle == true) {
                store.send(.setShuffle(shuffle: music?.shuffle != true))
            }.disabled(!store.musicAllows("toggling_shuffle"))
            RemoteMusicSwitch(
                title: L10n.text("Repeat"), on: music?.repeatMode != .off, value: repeatValue
            ) {
                store.send(
                    .setRepeat(
                        repeatMode: music?.repeatMode == .off
                            ? .all : music?.repeatMode == .all ? .one : .off))
            }
            .disabled(
                !store.musicAllows(
                    music?.repeatMode == .all || music?.repeatMode == .one
                        ? "toggling_repeat_track" : "toggling_repeat_context"))
            RemoteMusicSwitch(title: L10n.text("Favorite"), on: music?.liked == true, heart: true) {
                if let track = music?.track {
                    store.toggleMusicLike(trackId: track.id, currentlyLiked: music?.liked == true)
                }
            }
        }.disabled(!store.controlsEnabled || !store.state.hasMedia)
    }
    private var repeatValue: String {
        music?.repeatMode == .one
            ? L10n.text("Repeat one")
            : music?.repeatMode == .all ? L10n.text("Repeat all") : L10n.text("Off")
    }
}

struct RemoteMusicIcon: View {
    let name: String
    let size: CGFloat
    var body: some View {
        Image(name).renderingMode(name.hasPrefix("Spotify") ? .original : .template).resizable()
            .scaledToFit().frame(
                width: size, height: size
            ).accessibilityHidden(true)
    }
}

struct RemoteMusicSwitch: View {
    let title: String
    let on: Bool
    var heart = false
    var value: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if heart {
                    RemoteMusicIcon(name: on ? "SpotifySaved" : "SpotifyAdd", size: 16)
                        .foregroundStyle(on ? Palette.ember : Palette.textTertiary)
                } else {
                    Circle().fill(on ? Palette.ember : Palette.textTertiary).frame(
                        width: 6, height: 6)
                }
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity).frame(height: 44).background(
                Palette.glass, in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(
            value ?? (on ? L10n.text("On") : L10n.text("Off")))
    }
}
