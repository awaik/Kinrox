import MusicCore
import SwiftUI

/// Seed card: what the recommendations are based on, history and primary actions.
struct DiscoverySeedHeader: View {
    @Bindable var model: MusicViewModel
    let snapshot: MusicDiscoverySnapshot?
    @State private var dropTargeted = false

    private var seed: MusicDiscoverySeed? { snapshot?.seed }
    private var tracks: [MusicTrack] { snapshot?.displayTracks ?? [] }

    /// Track seeds are titled "Artists — Title"; show the bare track title for those only.
    /// Artist, album and playlist seeds keep their own titles.
    private func displayTitle(_ seed: MusicDiscoverySeed?) -> String {
        guard let seed, !seed.title.isEmpty else { return L10n.text("Liked tracks") }
        if let id = seed.trackID, let track = model.catalog.track(id: id),
            seed.title == "\(track.artistNames) — \(track.title)"
        {
            return track.title
        }
        return seed.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.canGoBackDiscovery, let previous = model.discoverySeedHistory.last {
                HStack(spacing: 6) {
                    Button {
                        model.goBackDiscoverySeed()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9, weight: .semibold))
                            Text(displayTitle(previous)).lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Back to the previous seed"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                    Text(displayTitle(seed))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            // Full button labels when they fit next to a reasonable title, icons otherwise.
            ViewThatFits(in: .horizontal) {
                seedRow(compact: false)
                seedRow(compact: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(dropTargeted ? Palette.ember.opacity(0.08) : .clear)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Palette.ember, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(6)
            }
        }
        .dropDestination(for: String.self) { values, _ in
            guard let payload = values.first else { return false }
            return reseed(with: payload)
        } isTargeted: {
            dropTargeted = $0
        }
    }

    /// Accepts the same drag payloads as the queue: tracks, albums, playlists and queue rows.
    private func reseed(with payload: String) -> Bool {
        if payload.hasPrefix("track:"),
            let track = model.catalog.track(id: String(payload.dropFirst(6)))
        {
            model.openSimilar(forTrack: track)
        } else if payload.hasPrefix("album:"),
            let album = model.catalog.album(id: String(payload.dropFirst(6)))
        {
            model.openSimilar(album: album)
        } else if payload.hasPrefix("playlist:"),
            let playlist = model.library.playlists.first(where: {
                $0.id == String(payload.dropFirst(9))
            })
        {
            model.openSimilar(playlist: playlist)
        } else if let id = UUID(uuidString: payload),
            let item = model.queue.items.first(where: { $0.id == id })
        {
            model.openSimilar(forTrack: item.track)
        } else {
            return false
        }
        return true
    }

    private func seedRow(compact: Bool) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Palette.emberDiagonal)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Similar to"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.flame)
                Text(displayTitle(seed))
                    .font(.system(size: 22, weight: .semibold).width(.expanded))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artists = seed?.artistNames, !artists.isEmpty {
                    Text(artists)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            // A modest ideal width lets ViewThatFits keep full labels for long titles.
            .frame(
                minWidth: compact ? 0 : 200, idealWidth: 220, maxWidth: .infinity,
                alignment: .leading
            )
            .help(L10n.text("Drop a track here to find music similar to it"))
            radioButton(compact: compact)
            actionButton(
                title: L10n.text("Add all to queue"), symbol: "plus", compact: compact
            ) {
                model.addTracksToQueue(tracks)
            }
            .disabled(tracks.isEmpty)
        }
    }

    private func actionButton(
        title: String, symbol: String, compact: Bool, primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if compact {
                Button(action: action) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(
                            primary ? Palette.textPrimary : Palette.glass,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(primary ? Palette.base : Palette.textPrimary)
                .help(title)
                .accessibilityLabel(title)
            } else {
                MusicActionButton(title: title, symbol: symbol, primary: primary, action: action)
            }
        }
    }

    @ViewBuilder
    private func radioButton(compact: Bool) -> some View {
        if model.isDiscoveryRadioActive {
            Button(action: model.stopDiscoveryRadio) {
                Group {
                    if compact {
                        Image(systemName: "stop.fill").font(.system(size: 12, weight: .semibold))
                    } else {
                        Label(
                            L10n.text("Playing similar · Stop"),
                            systemImage: "infinity")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Palette.flame)
                .padding(.horizontal, compact ? 12 : 14)
                .frame(height: 36)
                .background(Palette.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Palette.flame.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .help(L10n.text("Playing similar · Stop"))
            .accessibilityLabel(L10n.text("Stop adding similar tracks"))
        } else {
            actionButton(
                title: L10n.text("Listen to similar"), symbol: "infinity",
                compact: compact, primary: true, action: model.startDiscoveryRadio
            )
            .disabled(!model.canPlayLibrary || tracks.isEmpty)
            .help(L10n.text("Plays these tracks, then keeps adding similar ones on its own"))
        }
    }
}

/// Mode segmented control and filters.
struct DiscoveryControls: View {
    @Bindable var model: MusicViewModel
    let snapshot: MusicDiscoverySnapshot?

    var body: some View {
        // One row when there is room; otherwise genres move to a second row.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                primaryControls
                genreStrip.frame(minWidth: 220, idealWidth: 240, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    primaryControls
                    Spacer(minLength: 0)
                }
                genreStrip
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var primaryControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                segment(.sameSpirit, L10n.text("Same spirit"))
                segment(.underground, L10n.text("Underground"))
                segment(.fresh, L10n.text("Fresh"))
            }
            .padding(3)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("Discovery mode"))

            Rectangle().fill(Palette.hairline).frame(width: 1, height: 20)

            DiscoveryChip(
                title: L10n.text("Hide liked"), active: model.discoveryHideLiked,
                checkmark: true, action: model.toggleDiscoveryHideLiked)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var genreStrip: some View {
        if let snapshot, !snapshot.genres.isEmpty {
            genres(snapshot)
        }
    }

    private func segment(_ mode: MusicDiscoveryMode, _ title: String) -> some View {
        let active = model.discoveryMode == mode
        return Button {
            model.setDiscoveryMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(
                    active ? Palette.glassStrong : .clear, in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    if active { RoundedRectangle(cornerRadius: 6).stroke(Palette.strokeGlass) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func genres(_ snapshot: MusicDiscoverySnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text(L10n.text("Genres"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize()
                ForEach(snapshot.genres, id: \.self) { genre in
                    DiscoveryChip(
                        title: genre, active: model.discoverySelectedGenre == genre
                    ) { model.setDiscoveryGenre(genre) }
                }
            }
            .padding(.trailing, 28)
        }
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    colors: [.black, .clear], startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 28)
            }
        }
    }
}

struct DiscoveryChip: View {
    let title: String
    let active: Bool
    var checkmark = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if checkmark && active {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
                Text(title).lineLimit(1).fixedSize()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Palette.flame : Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(active ? Palette.ember.opacity(0.16) : Palette.glass, in: Capsule())
            .overlay { if active { Capsule().stroke(Palette.flame.opacity(0.45)) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
