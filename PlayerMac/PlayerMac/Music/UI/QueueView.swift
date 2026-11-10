import MusicCore
import SwiftUI

struct QueueView: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        VStack(spacing: 0) {
            CollectionHeader(model: model)
            MusicServiceStatus(model: model)
            GeometryReader { geometry in
                let columns = MusicTrackColumns(
                    width: max(0, geometry.size.width - 24), showAlbum: true)
                VStack(spacing: 0) {
                    MusicTrackHeader(showAlbum: true, columns: columns).padding(.horizontal, 12)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                section(
                                    L10n.text("Now Playing"),
                                    items: model.queue.current.map { [$0] } ?? [], columns: columns)
                                section(
                                    L10n.text("Added manually"), items: model.queue.manual,
                                    columns: columns)
                                section(
                                    L10n.text("From the source list"), items: model.queue.source,
                                    columns: columns)
                            }.padding(.horizontal, 12)
                        }.onChange(of: model.focusedQueueID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            }
        }.background(Palette.canvas).accessibilityElement(children: .contain).accessibilityLabel(
            L10n.text("Queue"))
    }

    @ViewBuilder
    private func section(
        _ title: String, items: [MusicQueueItem], columns: MusicTrackColumns
    ) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(
                .uppercase
            )
            .foregroundStyle(Palette.textTertiary).padding(.horizontal, 8).padding(.top, 12)
            .padding(.bottom, 6)
            ForEach(items) { item in
                MusicTrackRow(
                    model: model, track: item.track,
                    index: model.queue.items.firstIndex { $0.id == item.id } ?? 0,
                    showAlbum: true, columns: columns, anchor: item.id.uuidString,
                    queueID: item.id
                ) {
                    let items = model.queue.items
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        model.play(items.map(\.track), at: index)
                    }
                }.id(item.id)
            }
        }
    }
}

/// Persistent right-hand compact queue column (Figma page 09).
struct CompactQueueColumn: View {
    @Bindable var model: MusicViewModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isDiscoveryRadioActive { radioBanner }
            // The drop hint appears only while something is dragged over the queue.
            if dropTargeted { dropBanner }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let current = model.queue.current {
                            sectionTitle(L10n.text("Now Playing"))
                            CompactQueueRow(
                                model: model,
                                item: current,
                                isCurrent: true
                            )
                            .id(current.id)
                        }
                        if !model.queue.manual.isEmpty {
                            HStack {
                                sectionTitle(L10n.text("Added manually"))
                                Spacer(minLength: 4)
                                Button {
                                    model.clearManualQueue()
                                } label: {
                                    Text(L10n.text("Clear manual"))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Palette.flame)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 8)
                                .padding(.top, 6)
                            }
                            ForEach(model.queue.manual) { item in
                                CompactQueueRow(
                                    model: model,
                                    item: item,
                                    isCurrent: false
                                )
                                .id(item.id)
                            }
                        }
                        if !model.queue.source.isEmpty {
                            sectionTitle(L10n.text("From the source list"))
                            ForEach(model.queue.source) { item in
                                CompactQueueRow(
                                    model: model,
                                    item: item,
                                    isCurrent: false
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
                .onChange(of: model.focusedQueueID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .background(Palette.canvas)
        .dropDestination(for: String.self) { values, _ in
            guard let payload = values.first else { return false }
            return model.handleQueueDrop(payload, before: nil)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Queue"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Queue"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(model.queue.upcoming.count.formatted())
                .font(KinroxFont.monoDigits(11))
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Palette.glass, in: Capsule())
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var radioBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "infinity")
                .font(.system(size: 11, weight: .semibold))
            Text(L10n.text("Adding similar tracks as you listen"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(L10n.text("Stop"), action: model.stopDiscoveryRadio)
                .accessibilityLabel(L10n.text("Stop adding similar tracks"))
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
        }
        .foregroundStyle(Palette.flame)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Palette.ember.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.flame.opacity(0.4)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var dropBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.rectangle.on.folder")
                .font(.system(size: 11))
                .foregroundStyle(dropTargeted ? Palette.flame : Palette.textTertiary)
            Text(
                L10n.text(
                    "Drop track, album or playlist here — albums and playlists expand into tracks")
            )
            .font(.system(size: 10))
            .foregroundStyle(dropTargeted ? Palette.flame : Palette.textTertiary)
            .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            dropTargeted ? Palette.ember.opacity(0.15) : Palette.glass.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    dropTargeted ? Palette.ember : Palette.strokeGlass,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct CompactQueueRow: View {
    @Bindable var model: MusicViewModel
    let item: MusicQueueItem
    let isCurrent: Bool
    @State private var hovered = false
    @State private var rowTargeted = false

    private var track: MusicTrack { item.track }

    var body: some View {
        HStack(spacing: 8) {
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ember)
                    .frame(width: 18)
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(hovered ? Palette.textPrimary : Palette.textTertiary)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
                    .draggable(item.id.uuidString)
                    .accessibilityLabel(L10n.text("Reorder track"))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if track.explicit == true { SpotifyExplicitBadge() }
                    Text(track.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Palette.flame : Palette.textPrimary)
                        .lineLimit(1)
                }
                Text(track.artistNames)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isCurrent && hovered {
                HStack(spacing: 2) {
                    Button {
                        model.moveQueueOffset(item.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Move up"))
                    .accessibilityLabel(L10n.text("Move up"))

                    Button {
                        model.moveQueueOffset(item.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Move down"))
                    .accessibilityLabel(L10n.text("Move down"))
                }
                .foregroundStyle(Palette.textSecondary)
            } else {
                Text(TimeFormat.string(track.duration))
                    .font(KinroxFont.monoDigits(11))
                    .foregroundStyle(Palette.textTertiary)
            }

            if !isCurrent {
                Button {
                    model.removeFromQueue(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered ? Palette.textPrimary : Palette.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(
                            hovered ? Palette.glassStrong : .clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("Remove from queue"))
                .accessibilityLabel(L10n.text("Remove from queue"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            isCurrent
                ? Palette.ember.opacity(0.14)
                : (hovered ? Palette.glass : .clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    rowTargeted
                        ? Palette.flame
                        : (isCurrent ? Palette.ember.opacity(0.4) : .clear),
                    lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) {
            let items = model.queue.items
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                model.play(items.map(\.track), at: index)
            }
        }
        .onTapGesture {
            model.focusedColumn = .tracks
            model.focusTrack(track.id, queueID: item.id)
        }
        .contextMenu {
            if !isCurrent {
                Button(L10n.text("Move up")) { model.moveQueueOffset(item.id, by: -1) }
                Button(L10n.text("Move down")) { model.moveQueueOffset(item.id, by: 1) }
                Button(L10n.text("Remove from queue")) { model.removeFromQueue(item.id) }
                Divider()
            }
            Button(L10n.text("Similar")) { model.openSimilar(forTrack: track) }
            if let artist = track.artists.first {
                Button(L10n.text("Go to artist")) { model.navigateToArtist(artist) }
            }
            if !track.albumID.isEmpty {
                Button(L10n.text("Go to album")) {
                    model.navigateToAlbum(albumID: track.albumID, trackID: track.id)
                }
            }
        }
        .dropDestination(for: String.self) { values, _ in
            guard let payload = values.first else { return false }
            return model.handleQueueDrop(
                payload, before: isCurrent ? model.queue.upcoming.first?.id : item.id)
        } isTargeted: { targeted in
            rowTargeted = targeted
        }
    }
}
