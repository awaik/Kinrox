import AppKit
import SwiftUI

struct HomeOverviewView: View {
    @Bindable var session: PlayerSession
    let model: PlayerViewModel
    var showsCatalog = true

    var body: some View {
        let store = session.mediaLibrary
        let filter = session.homeFilter.overview
        let videos = store.filteredVideo(filter)
        let tracks = store.filteredTracks(filter)
        let albums = store.albums(in: tracks)
        let visiblePaths = Set(videos.map(\.id))
        let current = model.currentURL.map(VideoFiles.key)
        let libraryItems = store.continueWatching().filter {
            visiblePaths.contains($0.id) && $0.id != current
        }
        let indexedPaths = Set(store.snapshot.files.map(\.path))
        let adHocItems = session.recents.items.compactMap { item -> LocalVideoItem? in
            guard !session.recents.unavailable.contains(item.id),
                filter.query.isEmpty || item.title.localizedStandardContains(filter.query)
            else { return nil }
            let path = VideoFiles.key(URL(fileURLWithPath: item.path))
            guard path != current, !indexedPaths.contains(path),
                let progress = store.snapshot.progress[path], !progress.completed
            else { return nil }
            let file = MediaLibraryFile(
                path: path, size: 0, modified: item.openedAt, added: item.openedAt,
                video: VideoTitle(title: item.title))
            return LocalVideoItem(file: file, metadata: nil, progress: progress, isOffline: false)
        }
        let resume = libraryItems + adHocItems
        VStack(alignment: .leading, spacing: 20) {
            if !resume.isEmpty {
                sectionHeader(L10n.text("Continue Watching"), destination: .recent)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(resume.prefix(12)) { item in
                            Button {
                                model.resume(item.file.url, from: item.progress)
                            } label: {
                                HomeContinueCard(item: item, artwork: store.artwork).frame(
                                    width: 290)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.never)
            }
            if showsCatalog {
                sectionHeader(L10n.text("Movies & Series"), destination: .video)
                if videos.isEmpty { HomeNoMatches() }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(videoCards(videos, store: store).prefix(12)) { card in
                            Button {
                                if card.series != nil {
                                    session.homeSection = .video
                                    session.homeSelectedSeries = card.series?.id
                                } else {
                                    model.resume(card.item.file.url, from: card.item.progress)
                                }
                            } label: {
                                HomeVideoCard(card: card, artwork: store.artwork).frame(width: 150)
                            }
                            .buttonStyle(.plain)
                            .disabled(card.series == nil && card.item.isOffline)
                        }
                    }
                }.scrollIndicators(.never)
                sectionHeader(L10n.text("Music on This Mac"), destination: .audio)
                if albums.isEmpty {
                    if tracks.isEmpty {
                        HomeNoMatches()
                    } else {
                        LocalTrackTable(tracks: Array(tracks.prefix(4)), player: session.localAudio)
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(albums.prefix(12)) { album in
                                Button {
                                    session.homeSection = .audio
                                    session.homeSelectedAlbum = album.id
                                } label: {
                                    HomeAlbumCard(album: album, artwork: store.artwork).frame(
                                        width: 126)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }.scrollIndicators(.never)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, destination: HomeSection) -> some View {
        HStack {
            Text(title).font(KinroxFont.title)
            Spacer()
            Button {
                session.homeSection = destination
            } label: {
                Label(L10n.text("Show all  →"), systemImage: "chevron.right")
                    .labelStyle(.titleOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.flame)
            .font(KinroxFont.caption)
        }
    }
}

struct HomeContinueCard: View {
    let item: LocalVideoItem
    let artwork: ArtworkCache

    var body: some View {
        HStack(spacing: 10) {
            HomeArtwork(artwork: artwork, key: item.metadata?.posterPath, style: .still)
                .frame(width: 116, height: 66)
                .overlay {
                    Image(systemName: "play.circle.fill").font(.title3).symbolRenderingMode(
                        .hierarchical)
                }
                .overlay(alignment: .bottomLeading) {
                    if let progress = item.progress, progress.duration > 0 {
                        Capsule().fill(Palette.ember)
                            .frame(
                                width: 116 * min(1, progress.position / progress.duration),
                                height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.metadata?.title ?? item.file.title).font(KinroxFont.bodyStrong).lineLimit(
                    1)
                if item.file.seriesKey != nil {
                    let episode = LocalEpisodeItem(video: item)
                    Text(episode.title).lineLimit(1).foregroundStyle(Palette.textSecondary)
                }
                if let progress = item.progress, !progress.completed {
                    Text(TimeFormat.string(progress.position)).foregroundStyle(Palette.flame)
                }
            }
            .font(KinroxFont.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}

struct HomeArtwork: View {
    enum Style { case poster, album, still }
    let artwork: ArtworkCache
    let key: String?
    let style: Style
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        style == .album
                            ? Color(red: 0.19, green: 0.13, blue: 0.25)
                            : Palette.ember.opacity(0.34),
                        Palette.canvas,
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if style == .album {
                    let width = min(proxy.size.width, proxy.size.height)
                    Image("HomeVinylMotif").resizable().scaledToFit()
                        .frame(width: width * 0.52)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: width * 0.17, weight: .semibold))
                                .foregroundStyle(Palette.textSecondary)
                        }
                } else {
                    Image("HomePosterSun").resizable().scaledToFit()
                        .frame(width: min(proxy.size.width, proxy.size.height) * 0.68)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: key) {
            let data = if let key { await artwork.thumbnail(key) } else { nil as Data? }
            if !Task.isCancelled { image = data.flatMap(NSImage.init(data:)) }
        }
        .accessibilityHidden(true)
    }
}

struct HomeRatingBadge: View {
    let rating: Double?
    var body: some View {
        if let rating {
            Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                .font(KinroxFont.caption).foregroundStyle(Palette.flame)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct HomeNoMatches: View {
    var body: some View {
        Text(L10n.text("No results"))
            .font(KinroxFont.body).foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
}
