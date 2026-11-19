import AppKit
import SwiftUI

struct HomeRecentView: View {
    let session: PlayerSession
    let model: PlayerViewModel
    let actions: PlayerActions

    var body: some View {
        let recents = session.recents
        let query = session.homeFilter.query
        let items = recents.items.filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
        }
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Recent")).font(KinroxFont.titleLarge())
            if items.isEmpty {
                Text(L10n.text("No results")).foregroundStyle(Palette.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(items) { item in
                    let key = VideoFiles.key(URL(fileURLWithPath: item.path))
                    let current = model.hasMedia && model.currentURL.map(VideoFiles.key) == key
                    RecentCard(
                        item: item, isAvailable: !recents.unavailable.contains(item.id),
                        isCurrent: current,
                        open: {
                            if current {
                                model.returnToVideo()
                            } else if let url = recents.resolve(item),
                                let progress = session.mediaLibrary.snapshot.progress[key]
                            {
                                model.resume(url, from: progress)
                            } else {
                                actions.openRecent(item)
                            }
                        },
                        revealInFinder: {
                            if let url = recents.resolve(item) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } else {
                                recents.refreshAvailability()
                            }
                        },
                        remove: { recents.remove(item.id) })
                }
            }
        }
    }
}
