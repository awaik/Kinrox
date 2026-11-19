import SwiftUI

struct HomeLocalMusicView: View {
    @Bindable var session: PlayerSession

    var body: some View {
        let store = session.mediaLibrary
        let player = session.localAudio
        let tracks = store.filteredTracks(session.homeFilter)
        let albums = store.albums(in: tracks)
        let visible =
            session.homeSelectedAlbum.flatMap { album in
                albums.first(where: { $0.id == album })?.tracks
            } ?? tracks
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("Music on This Mac")).font(KinroxFont.titleLarge())
                Text(L10n.text("Local Audio")).overlineStyle(Palette.online).lineLimit(1)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    playButtons(visible)
                    Spacer()
                    filters
                }
                VStack(alignment: .leading) {
                    playButtons(visible)
                    filters
                }
            }
            if !albums.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(albums) { album in
                            Button {
                                session.homeSelectedAlbum =
                                    session.homeSelectedAlbum == album.id ? nil : album.id
                            } label: {
                                HomeAlbumCard(album: album, artwork: store.artwork)
                                    .frame(width: 146)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10).strokeBorder(
                                            session.homeSelectedAlbum == album.id
                                                ? Palette.flame : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.never)
            }
            if visible.isEmpty {
                HomeNoMatches()
            } else {
                LocalTrackTable(tracks: visible, player: player)
            }
        }
    }

    private func playButtons(_ tracks: [LocalAudioTrack]) -> some View {
        let playable = tracks.filter { !$0.isOffline }
        return HStack(spacing: 7) {
            HomePill(title: L10n.text("Play All"), icon: "play.fill", prominent: true) {
                session.localAudio.play(playable)
            }
            HomePill(title: L10n.text("Shuffle"), icon: "shuffle") {
                session.localAudio.play(playable, shuffled: true)
            }
            if session.homeSelectedAlbum != nil {
                HomePill(title: L10n.text("All tracks")) { session.homeSelectedAlbum = nil }
            }
        }
        .disabled(playable.isEmpty)
    }

    private var filters: some View {
        HStack(spacing: 7) {
            HomePill(title: L10n.text("Lossless"), prominent: session.homeFilter.lossless) {
                session.homeFilter.lossless.toggle()
            }
            HomePill(
                title: "4.0+", icon: "star.fill", prominent: session.homeFilter.audioMinimumRating
            ) {
                session.homeFilter.audioMinimumRating.toggle()
            }
            HomeCatalogMenus(session: session)
        }
    }
}

struct HomeAlbumCard: View {
    let album: LocalAudioAlbum
    let artwork: ArtworkCache

    var body: some View {
        if let track = album.tracks.first {
            VStack(alignment: .leading, spacing: 6) {
                HomeArtwork(
                    artwork: artwork, key: album.tracks.compactMap(\.artworkPath).first,
                    style: .album
                )
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    HomeRatingBadge(rating: track.rating).padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    Text(track.format).font(KinroxFont.caption)
                        .foregroundStyle(
                            track.file.audio?.isLossless == true
                                ? Palette.online : Palette.textPrimary
                        )
                        .padding(5).background(
                            .black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5)
                        ).padding(7)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
                Text(track.album).font(KinroxFont.bodyStrong).lineLimit(1)
                Text(
                    ([track.file.audio?.albumArtist ?? track.artist] + track.genres).joined(
                        separator: " · ")
                )
                .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(album.tracks.allSatisfy(\.isOffline) ? 0.5 : 1)
        }
    }
}

struct LocalTrackTable: View {
    let tracks: [LocalAudioTrack]
    let player: LocalAudioViewModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            cells([
                "#", L10n.text("Title"), L10n.text("Artist"), L10n.text("Album"),
                L10n.text("Genres"), L10n.text("Rating"), L10n.text("Format"),
                L10n.text("Duration"),
            ])
            .foregroundStyle(Palette.textTertiary)
            .accessibilityHidden(true)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                let current = player.currentTrack?.id == track.id
                Button {
                    if current { player.togglePause() } else { player.play(tracks, at: index) }
                } label: {
                    cells(
                        [
                            current
                                ? (player.paused ? "Ⅱ" : "▶")
                                : (track.file.audio?.track ?? index + 1).formatted(),
                            track.title, track.artist, albumCaption(track),
                            track.genres.joined(separator: " · "),
                            track.rating.map {
                                "★ " + $0.formatted(.number.precision(.fractionLength(1)))
                            } ?? "—",
                            format(track),
                            track.file.audio?.duration.map { TimeFormat.string($0) } ?? "—",
                        ], lossless: track.file.audio?.isLossless == true
                    )
                    .background(
                        current ? Palette.glassStrong : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7).strokeBorder(
                            current ? Palette.ember : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(track.title)
                .disabled(track.isOffline)
                .opacity(track.isOffline ? 0.45 : 1)
            }
        }
        .font(KinroxFont.caption)
    }

    private func cells(_ values: [String], lossless: Bool = false) -> some View {
        HStack(spacing: 7) {
            Text(values[0]).frame(width: 24, alignment: .trailing)
            Text(values[1]).frame(maxWidth: .infinity, alignment: .leading)
            Text(values[2]).frame(maxWidth: .infinity, alignment: .leading)
            Text(values[3]).frame(maxWidth: .infinity, alignment: .leading)
            Text(values[4]).frame(maxWidth: .infinity, alignment: .leading)
            Text(values[5]).foregroundStyle(
                values[5].hasPrefix("★") ? Palette.flame : Palette.textSecondary
            )
            .frame(width: 42, alignment: .leading)
            Text(values[6]).foregroundStyle(lossless ? Palette.online : Palette.textSecondary)
                .frame(width: 76, alignment: .leading)
            Text(values[7]).frame(width: 56, alignment: .trailing).monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(minHeight: 28)
    }

    private func albumCaption(_ track: LocalAudioTrack) -> String {
        let year = track.file.audio?.year.map(String.init) ?? track.metadata?.year
        return [track.album, year ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func format(_ track: LocalAudioTrack) -> String {
        if let depth = track.file.audio?.bitDepth, let rate = track.file.audio?.sampleRate {
            return
                "\(track.format) \(depth)/\((Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...1))))"
        }
        return track.format
    }
}
