import AppKit
import SwiftUI

struct HomeVideoLibraryView: View {
    @Bindable var session: PlayerSession
    let model: PlayerViewModel

    var body: some View {
        let store = session.mediaLibrary
        let cards = videoCards(store.filteredVideo(session.homeFilter), store: store)
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Movies & Series")).font(KinroxFont.titleLarge())
            ViewThatFits(in: .horizontal) {
                HStack {
                    kinds
                    Spacer()
                    filters
                }
                VStack(alignment: .leading) {
                    kinds
                    filters
                }
            }
            if let card = cards.first(where: {
                $0.series?.id == session.homeSelectedSeries && $0.series != nil
            }),
                let series = card.series
            {
                SeriesDetailCard(
                    group: series, artwork: store.artwork, model: model,
                    close: { session.homeSelectedSeries = nil }
                )
                .id(series.id)
            }
            if cards.isEmpty { HomeNoMatches() }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], alignment: .leading,
                spacing: 20
            ) {
                ForEach(cards) { card in
                    Button {
                        if let series = card.series {
                            session.homeSelectedSeries =
                                session.homeSelectedSeries == series.id ? nil : series.id
                        } else {
                            model.resume(card.item.file.url, from: card.item.progress)
                        }
                    } label: {
                        HomeVideoCard(card: card, artwork: store.artwork)
                    }
                    .buttonStyle(.plain)
                    .disabled(card.series == nil && card.item.isOffline)
                    .contextMenu {
                        if !card.item.isOffline {
                            Button(L10n.text("Show in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([card.item.file.url])
                            }
                        }
                    }
                }
            }
        }
    }

    private var kinds: some View {
        HStack(spacing: 6) {
            ForEach(HomeFilterState.VideoKind.allCases, id: \.self) { kind in
                HomePill(title: kind.title, prominent: session.homeFilter.videoKind == kind) {
                    session.homeFilter.videoKind = kind
                }
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            HomePill(
                title: "8.0+", icon: "star.fill", prominent: session.homeFilter.videoMinimumRating
            ) {
                session.homeFilter.videoMinimumRating.toggle()
            }
            HomePill(title: "4K HDR", prominent: session.homeFilter.ultraHD) {
                session.homeFilter.ultraHD.toggle()
            }
            HomeCatalogMenus(session: session)
        }
    }
}

struct SeriesDetailCard: View {
    let group: LocalSeriesGroup
    let artwork: ArtworkCache
    let model: PlayerViewModel
    let close: () -> Void
    @State private var selectedSeason: Int?
    @State private var selectedEpisode: String?

    var body: some View {
        if let first = group.episodes.first {
            let metadata = first.video.metadata
            let chosen =
                group.episodes.first { $0.id == selectedEpisode }
                ?? (selectedSeason == nil ? group.next : nil)
                ?? group.episodes.first { $0.season == selectedSeason } ?? first
            let seasons = Set(group.episodes.map(\.season)).sorted()
            HStack(alignment: .top, spacing: 16) {
                HomeArtwork(artwork: artwork, key: metadata?.posterPath, style: .poster)
                    .frame(width: 135, height: 192)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(group.title).font(KinroxFont.titleLarge()).lineLimit(2)
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.text("Close"))
                    }
                    HStack(spacing: 6) {
                        HomeRatingBadge(rating: metadata?.rating)
                        if let source = metadata?.source {
                            if source == .tvmaze {
                                Link("TVMaze", destination: URL(string: "https://www.tvmaze.com/")!)
                                    .font(KinroxFont.caption).foregroundStyle(Palette.flame)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Palette.glassStrong, in: Capsule())
                            } else {
                                Text(source.rawValue).font(KinroxFont.caption)
                            }
                        }
                        if let year = metadata?.year { Text(year).font(KinroxFont.caption) }
                        Text(metadata?.genres.joined(separator: " · ") ?? "")
                            .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                    if let summary = metadata?.summary {
                        Text(summary).font(KinroxFont.caption).foregroundStyle(
                            Palette.textSecondary
                        ).lineLimit(3)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { playControls(chosen, seasons: seasons) }
                        VStack(alignment: .leading, spacing: 6) {
                            playControls(chosen, seasons: seasons)
                        }
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(group.episodes.filter { $0.season == chosen.season }) {
                                episode in
                                HomePill(
                                    title: "\(episodeCode(episode)) · \(episode.title)",
                                    prominent: episode.id == chosen.id
                                ) { selectedEpisode = episode.id }
                                .opacity(episode.video.isOffline ? 0.45 : 1)
                                .help(
                                    episode.video.progress?.completed == true
                                        ? L10n.text("Watched") : episode.title)
                            }
                        }
                    }.scrollIndicators(.never)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.ember))
        }
    }

    @ViewBuilder private func playControls(_ chosen: LocalEpisodeItem, seasons: [Int]) -> some View
    {
        HomePill(
            title: L10n.format("Continue %@", episodeCode(chosen)), icon: "play.fill",
            prominent: true
        ) { model.resume(chosen.video.file.url, from: chosen.video.progress) }
        .disabled(chosen.video.isOffline)
        Menu(L10n.format("Season %@", chosen.season.formatted())) {
            ForEach(seasons, id: \.self) { season in
                Button(L10n.format("Season %@", season.formatted())) {
                    selectedSeason = season
                    selectedEpisode = nil
                }
            }
        }.fixedSize()
        HomePill(title: L10n.text("Audio & Subtitles")) {
            model.resume(chosen.video.file.url, from: chosen.video.progress, showTracks: true)
        }.disabled(chosen.video.isOffline)
        HomePill(title: L10n.text("Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([chosen.video.file.url])
        }.disabled(chosen.video.isOffline)
    }

    private func episodeCode(_ episode: LocalEpisodeItem) -> String {
        String(format: "S%02dE%02d", episode.season, episode.number)
    }
}

struct HomeVideoCardData: Identifiable {
    let item: LocalVideoItem
    var series: LocalSeriesGroup?
    var id: String { series?.id ?? item.id }
}

@MainActor
func videoCards(_ items: [LocalVideoItem], store: MediaLibraryStore) -> [HomeVideoCardData] {
    let groups = Dictionary(
        uniqueKeysWithValues: store.series(in: store.videoItems).map { ($0.id, $0) })
    var seen: Set<String> = []
    return items.compactMap { item in
        guard let series = item.file.seriesKey else { return HomeVideoCardData(item: item) }
        guard seen.insert(series).inserted else { return nil }
        return HomeVideoCardData(item: item, series: groups[series])
    }
}

struct HomeVideoCard: View {
    let card: HomeVideoCardData
    let artwork: ArtworkCache

    var body: some View {
        let item = card.item
        VStack(alignment: .leading, spacing: 6) {
            HomeArtwork(artwork: artwork, key: item.metadata?.posterPath, style: .poster)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    HomeRatingBadge(rating: item.metadata?.rating).padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    Text(badge).font(KinroxFont.caption).lineLimit(1)
                        .padding(5).background(
                            .black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5)
                        ).padding(7)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
            Text(item.metadata?.title ?? item.file.title).font(KinroxFont.bodyStrong).lineLimit(1)
            Text(caption).font(KinroxFont.caption).foregroundStyle(Palette.textSecondary).lineLimit(
                1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(item.isOffline ? 0.5 : 1)
    }

    private var badge: String {
        if let group = card.series {
            return L10n.format("Episodes: %@", group.episodes.count.formatted())
        }
        let video = card.item.file.video
        return [video?.resolution, video?.hdr, video?.codec, card.item.file.container]
            .compactMap { $0 }.prefix(2).joined(separator: " · ")
    }

    private var caption: String {
        let item = card.item
        if item.isOffline { return L10n.text("Drive disconnected") }
        return
            ([item.metadata?.year ?? item.file.video?.year.map(String.init)].compactMap { $0 }
            + (item.metadata?.genres ?? [])).joined(separator: " · ")
    }
}

struct HomeCatalogMenus: View {
    @Bindable var session: PlayerSession

    var body: some View {
        Menu(session.homeFilter.genre ?? L10n.text("Genres")) {
            Button(L10n.text("All")) { session.homeFilter.genre = nil }
            ForEach(session.mediaLibrary.catalogGenres, id: \.self) { genre in
                Button(genre) { session.homeFilter.genre = genre }
            }
        }
        .frame(maxWidth: 145)
        Picker(L10n.text("Sort"), selection: $session.homeFilter.sort) {
            ForEach(HomeFilterState.Sort.allCases, id: \.self) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 125)
    }
}

extension HomeFilterState.VideoKind {
    fileprivate var title: String {
        switch self {
        case .all: L10n.text("All")
        case .movies: L10n.text("Movies")
        case .series: L10n.text("Series")
        case .unwatched: L10n.text("Unwatched")
        }
    }
}

extension HomeFilterState.Sort {
    fileprivate var title: String {
        switch self {
        case .title: L10n.text("Title")
        case .rating: L10n.text("Rating")
        case .recent: L10n.text("Recent")
        }
    }
}
