import SwiftUI

struct HomeSidebarView: View {
    @Bindable var session: PlayerSession
    let actions: PlayerActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("Media Library")).overlineStyle()
                    VStack(spacing: 4) {
                        ForEach(HomeSection.allCases, id: \.self) { section in
                            Button {
                                session.homeSection = section
                            } label: {
                                HStack {
                                    Label(section.title, systemImage: section.icon).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(count(section).formatted()).foregroundStyle(
                                        Palette.textTertiary)
                                }
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(
                                    session.homeSection == section ? Palette.glassStrong : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(
                                session.homeSection == section ? .isSelected : [])
                        }
                    }
                    let genres = session.mediaLibrary.catalogGenres
                    if !genres.isEmpty {
                        Text(L10n.text("Genres")).overlineStyle()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], alignment: .leading)
                        {
                            ForEach(Array(genres.prefix(6)), id: \.self) { genre in
                                HomePill(title: genre, prominent: session.homeFilter.genre == genre)
                                {
                                    session.homeFilter.genre =
                                        session.homeFilter.genre == genre ? nil : genre
                                }
                            }
                        }
                    }
                    HStack {
                        Button {
                            session.isLibrarySheetShown = true
                        } label: {
                            Text(L10n.text("Folders")).overlineStyle()
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        HomePill(
                            title: L10n.text("Add"), icon: "plus", prominent: true,
                            action: actions.chooseFolders)
                    }
                    ForEach(session.mediaLibrary.folders) { folder in
                        Button {
                            session.isLibrarySheetShown = true
                        } label: {
                            LibraryFolderRow(
                                folder: folder, state: session.mediaLibrary.states[folder.id],
                                fileCount: session.mediaLibrary.snapshot.fileCounts[
                                    folder.id, default: 0]
                            )
                            .padding(8)
                            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.never)
            Button {
                session.isLibrarySheetShown = true
            } label: {
                Label(
                    session.mediaLibrary.autoWatchFolders
                        ? L10n.text("Automatic Folder Scanning") : L10n.text("Check Now"),
                    systemImage: session.mediaLibrary.autoWatchFolders
                        ? "arrow.trianglehead.clockwise" : "folder"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            HomePill(title: L10n.text("Open File…"), icon: "folder", action: actions.openFile)
                .help("⌘O")
        }
        .font(KinroxFont.caption)
        .padding(12)
        .background(Palette.canvas)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1) }
    }

    private func count(_ section: HomeSection) -> Int {
        switch section {
        case .overview: session.mediaLibrary.snapshot.files.count
        case .video: session.mediaLibrary.videoItems.count
        case .audio: session.mediaLibrary.audioTracks.count
        case .recent: session.recents.items.count
        }
    }
}

struct HomePill: View {
    let title: String
    var icon: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title).lineLimit(1)
            }
            .font(KinroxFont.caption)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(prominent ? Palette.ember : Palette.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
