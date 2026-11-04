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
