import SwiftUI

struct LibraryFoldersSheet: View {
    let store: MediaLibraryStore
    let actions: PlayerActions
    @Environment(\.dismiss) private var dismiss
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("Media Library Folders")).font(KinroxFont.titleLarge())
                Spacer()
                HomePill(title: L10n.text("Check Now"), icon: "arrow.clockwise") {
                    store.rescanAll(refreshMetadata: true)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Drop folders with movies or music here")).font(
                        KinroxFont.bodyStrong)
                    Text("MKV, MP4, MOV, WebM · FLAC, ALAC, MP3, WAV, M4A")
                        .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                HomePill(
                    title: L10n.text("Add Folder…"), icon: "folder.badge.plus", prominent: true,
                    action: actions.chooseFolders)
            }
            .padding(16)
            .background(
                dropping ? Palette.glassStrong : Palette.glass,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    dropping ? Palette.ember : Palette.hairline, style: StrokeStyle(dash: [5, 4]))
            )
            .dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter {
                    $0.isFileURL
                        && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                actions.addFolders(folders)
                return !folders.isEmpty
            } isTargeted: {
                dropping = $0
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.folders) { folder in
                            HStack {
                                LibraryFolderRow(
                                    folder: folder, state: store.states[folder.id],
                                    fileCount: store.snapshot.fileCounts[folder.id, default: 0],
                                    showStatus: true)
                                Menu {
                                    Button(L10n.text("Remove Folder"), role: .destructive) {
                                        store.removeFolder(folder.id)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                            .padding(12)
                            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10).strokeBorder(
                                    store.focusedFolder == folder.id
                                        ? Palette.ember : Palette.hairline)
                            )
                            .id(folder.id)
                        }
                    }
                }
                .frame(maxHeight: 275)
                .onChange(of: store.focusedFolder, initial: true) { _, folder in
                    if let folder { proxy.scrollTo(folder) }
                }
            }
            if store.storageFailed {
                Text(L10n.text("The media library could not be updated."))
                    .foregroundStyle(Palette.flame)
            }
            MediaLibrarySettingsCard(store: store, showHeading: false)
            HStack {
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 590)
        .background(Palette.elevated)
    }
}

struct LibraryFolderRow: View {
    let folder: WatchedFolder
    let state: FolderScanState?
    var fileCount: Int? = nil
    var showStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: folder.isRemovable ? "externaldrive.fill" : "folder.fill")
                    .foregroundStyle(Palette.flame)
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.displayName).font(KinroxFont.bodyStrong).lineLimit(1)
                    Text(folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(
                        Palette.textTertiary)
                    if case .scanning = state {
                        EmptyView()
                    } else if let fileCount, showStatus {
                        Text(L10n.format("Files checked: %@", fileCount.formatted()))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if state == .failed {
                    status(
                        L10n.text("Folder could not be scanned."), icon: "exclamationmark.circle",
                        tint: Palette.flame)
                } else if folder.isOffline || state == .offline {
                    status(
                        L10n.text("Drive disconnected"), icon: "externaldrive.badge.minus",
                        tint: Palette.textSecondary)
                } else if case .scanning = state {
                    status(L10n.text("Scanning…"), icon: "arrow.clockwise", tint: Palette.flame)
                } else {
                    status(
                        L10n.text("Up to date"), icon: "checkmark.circle.fill", tint: Palette.online
                    )
                }
            }
            if case .scanning(let count) = state {
                if showStatus {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.format("Files checked: %@", count.formatted()))
                            .foregroundStyle(Palette.textSecondary)
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
        }
        .font(KinroxFont.caption)
    }

    private func status(_ title: String, icon: String, tint: Color) -> some View {
        Group {
            if showStatus { Text(title) } else { Image(systemName: icon).accessibilityLabel(title) }
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .help(title)
    }
}

struct MediaLibrarySettingsCard: View {
    let store: MediaLibraryStore
    var showHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeading { Text(L10n.text("Media Library")).overlineStyle() }
            Toggle(
                isOn: Binding(
                    get: { store.autoWatchFolders }, set: { store.setAutoWatchFolders($0) })
            ) {
                Text(L10n.text("Automatic Folder Scanning"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(
                isOn: Binding(get: { store.enrichMetadata }, set: { store.setEnrichMetadata($0) })
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Load ratings, genres, and artwork"))
                    Text(
                        L10n.text(
                            "Media titles and album artists are sent to Cinemeta, TVMaze, MusicBrainz, and Cover Art Archive."
                        )
                    )
                    .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toggleStyle(.switch)
        .tint(Palette.ember)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}
