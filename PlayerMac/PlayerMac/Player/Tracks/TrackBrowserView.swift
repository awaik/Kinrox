import SwiftUI

struct TrackBrowserView: View {
    @Bindable var controller: TrackController
    @State private var query = ""
    @State private var kind: MediaTrackKind?
    @State private var folder = ""

    private var folders: [String] {
        var paths: Set<String> = []
        for file in controller.files {
            var parts = file.folder.split(separator: "/").map(String.init)
            while !parts.isEmpty {
                paths.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filtered: [TrackFile] {
        controller.files.filter { file in
            (kind == nil || kind == file.kind)
                && (folder.isEmpty || file.folder == folder || file.folder.hasPrefix(folder + "/"))
                && (query.isEmpty || file.relativePath.localizedStandardContains(query)
                    || controller.loadedTrack(for: file)?.displayTitle.localizedStandardContains(
                        query) == true)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 440
            VStack(alignment: .leading, spacing: compact ? 8 : 16) {
                TrackPanelHeader(title: L10n.text("All files in folder")) {
                    controller.presentation = .quick
                }
                if !compact {
                    Text(
                        L10n.format(
                            "%@ · %@ files", controller.settings?.root.lastPathComponent ?? "",
                            String(controller.files.count))
                    )
                    .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                    TextField(L10n.text("Language, release group or filename"), text: $query)
                        .textFieldStyle(.plain).accessibilityIdentifier("track-file-search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear search"))
                    }
                }
                .padding(compact ? 8 : 12)
                .background(Palette.glass, in: RoundedRectangle(cornerRadius: 10))
                HStack(alignment: .top, spacing: 24) {
                    if geometry.size.width >= 760 { folderTree.frame(width: 220) }
                    VStack(alignment: .leading, spacing: compact ? 4 : 12) {
                        HStack {
                            filterButton(nil, title: L10n.text("All"))
                            ForEach(MediaTrackKind.allCases) { type in
                                filterButton(type, title: type.label)
                            }
                            if compact, geometry.size.width < 760 { folderPicker.labelsHidden() }
                        }
                        if !compact, geometry.size.width < 760 { folderPicker }
                        fileList
                    }
                }
                TrackStatusView(controller: controller)
                HStack {
                    Button(L10n.text("Choose search folder…")) { controller.presentation = .scope }
                        .buttonStyle(.plain).foregroundStyle(Palette.flame)
                    Spacer()
                    Button(L10n.text("Refresh list")) { controller.refresh() }
                        .buttonStyle(.bordered)
                }.font(KinroxFont.bodyStrong).disabled(controller.isChoosingFile)
            }
            .padding(compact ? 16 : 24).foregroundStyle(Palette.textPrimary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track-file-browser")
        .onChange(of: controller.isScanning) { _, scanning in
            if !scanning, !folders.contains(folder) { folder = "" }
        }
    }

    private var folderPicker: some View {
        Picker(L10n.text("Folder"), selection: $folder) {
            Text(controller.settings?.root.lastPathComponent ?? "").tag("")
            // Retain the current tag while a new scan rebuilds the folder list.
            if !folder.isEmpty, !folders.contains(folder) { Text(folder).tag(folder) }
            ForEach(folders, id: \.self) { Text($0).tag($0) }
        }
        .lineLimit(1)
    }

    private var folderTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Folders")).overlineStyle().padding(.bottom, 4)
                folderButton("", title: controller.settings?.root.lastPathComponent ?? "")
                ForEach(folders, id: \.self) { path in
                    folderButton(path, title: (path as NSString).lastPathComponent)
                        .padding(.leading, CGFloat(min(6, path.split(separator: "/").count)) * 12)
                }
            }.padding(12)
        }.background(Palette.glass, in: RoundedRectangle(cornerRadius: 12))
    }

    private func folderButton(_ path: String, title: String) -> some View {
        Button {
            folder = path
        } label: {
            Label(title, systemImage: "folder")
                .font(KinroxFont.body).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                .background(
                    folder == path ? Palette.glassStrong : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(path)
    }

    private func filterButton(_ type: MediaTrackKind?, title: String) -> some View {
        let count = controller.files.filter { type == nil || $0.kind == type }.count
        return Button {
            kind = type
        } label: {
            Text(L10n.format("%@ · %@", title, String(count))).font(KinroxFont.bodyStrong)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(
                    kind == type ? Palette.glassStrong : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(kind == type ? .isSelected : [])
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            controller.isScanning
                                ? L10n.text("Searching for tracks…")
                                : controller.files.isEmpty
                                    ? L10n.text("No external tracks found")
                                    : L10n.text("No results")
                        )
                        .font(KinroxFont.title)
                        Text(
                            controller.files.isEmpty
                                ? L10n.text("Embedded tracks are available in the selector.")
                                : L10n.text("Try another language, release group or filename.")
                        )
                        .font(KinroxFont.body).foregroundStyle(Palette.textSecondary)
                        if !query.isEmpty || kind != nil || !folder.isEmpty {
                            Button(L10n.text("Clear search")) {
                                query = ""
                                kind = nil
                                folder = ""
                            }
                        }
                    }.padding(.vertical, 20)
                }
                fileSection(filtered.filter(\.matchesVideo), title: L10n.text("For this episode"))
                fileSection(
                    filtered.filter { !$0.matchesVideo },
                    title: L10n.text("Other episodes and files"))
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ files: [TrackFile], title: String) -> some View {
        if !files.isEmpty {
            Text(title).overlineStyle().padding(.vertical, 10)
            ForEach(files) { file in
                let loaded = controller.loadedTrack(for: file)
                TrackChoiceRow(
                    title: loaded?.displayTitle ?? file.title,
                    detail: file.relativePath, selected: loaded?.isSelected ?? false,
                    pending: controller.isPending(file)
                ) { controller.select(file) }
            }
        }
    }
}
