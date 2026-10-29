import SwiftUI

/// Figma 04 / Quick selection. Short windows scroll the complete panel.
struct TrackSelectionView: View {
    @Bindable var controller: TrackController

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.height < 500 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heading
                        trackList
                        footer
                    }.padding(20)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    ScrollView { trackList }
                    footer
                }.padding(20)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track-selection-panel")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackPanelHeader(title: L10n.text("Audio & Subtitles")) {
                controller.presentation = nil
            }
            Text(controller.video?.deletingPathExtension().lastPathComponent ?? "")
                .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                ForEach(MediaTrackKind.allCases) { kind in
                    Button {
                        controller.selectedKind = kind
                    } label: {
                        Text(
                            L10n.format(
                                "%@ · %@", kind.label,
                                String(
                                    controller.available(kind).count
                                        + controller.matchingFiles(kind).count))
                        )
                        .font(KinroxFont.bodyStrong)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(
                            controller.selectedKind == kind
                                ? Palette.textPrimary : Palette.textSecondary
                        )
                        .background(
                            controller.selectedKind == kind ? Palette.glassStrong : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(controller.selectedKind == kind ? .isSelected : [])
                }
            }
            .padding(4).background(Palette.glass, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("Track type"))
            Text(L10n.text("For this episode")).overlineStyle(Palette.textSecondary)
        }
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            if controller.selectedKind == .subtitle {
                TrackChoiceRow(
                    title: L10n.text("Off"), detail: L10n.text("Do not show subtitles"),
                    selected: !controller.available(.subtitle).contains(where: \.isSelected)
                ) {
                    controller.disableSubtitles()
                }
            }
            ForEach(controller.available(controller.selectedKind)) { track in
                TrackChoiceRow(
                    title: track.displayTitle,
                    detail: track.detail(relativeTo: controller.settings?.root),
                    selected: track.isSelected
                ) { controller.select(track) }
            }
            ForEach(controller.matchingFiles(controller.selectedKind)) { file in
                TrackChoiceRow(
                    title: file.title, detail: file.relativePath,
                    pending: controller.isPending(file)
                ) { controller.select(file) }
            }
            if controller.available(controller.selectedKind).isEmpty
                && controller.matchingFiles(controller.selectedKind).isEmpty
            {
                Text(L10n.text("No tracks found.")).font(KinroxFont.body)
                    .foregroundStyle(Palette.textSecondary).padding(.vertical, 16)
            }
        }.disabled(!controller.isReady || controller.isChoosingFile)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackStatusView(controller: controller)
            TrackActionButton(
                title: L10n.format("All files in folder · %@", String(controller.files.count))
            ) {
                controller.presentation = .browser
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.settings?.root.lastPathComponent ?? "")
                if controller.settings?.recursive == true {
                    Text(L10n.text("Including all subfolders"))
                }
            }.font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
            HStack {
                Button(L10n.text("Choose search folder…")) { controller.presentation = .scope }
                    .buttonStyle(.plain).foregroundStyle(Palette.flame).font(KinroxFont.bodyStrong)
                Spacer()
                IconButton(
                    systemName: "plus",
                    help: controller.selectedKind == .audio
                        ? L10n.text("Add Audio File…") : L10n.text("Add Subtitle File…")
                ) {
                    TrackFilePanels.openTrack(controller)
                }
                IconButton(systemName: "arrow.clockwise", help: L10n.text("Refresh list")) {
                    controller.refresh()
                }
            }.disabled(controller.isChoosingFile)
        }
    }
}

struct TrackPanelHeader: View {
    let title: String
    let close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(KinroxFont.title)
            Spacer()
            IconButton(systemName: "xmark", help: L10n.text("Close"), action: close)
        }.foregroundStyle(Palette.textPrimary)
    }
}

struct TrackChoiceRow: View {
    let title: String
    let detail: String
    var selected = false
    var pending = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(KinroxFont.bodyStrong).foregroundStyle(Palette.textPrimary)
                    Text(detail).font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                }.lineLimit(1).truncationMode(.middle).frame(
                    maxWidth: .infinity, alignment: .leading)
                if pending {
                    ProgressView().controlSize(.small)
                } else if selected {
                    Image(systemName: "checkmark").foregroundStyle(Palette.flame)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 60)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                selected ? Palette.glassStrong : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).help([title, detail].joined(separator: "\n"))
        .disabled(pending)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TrackActionButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(KinroxFont.bodyStrong).frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(Palette.textPrimary)
                .background(Palette.glass, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

struct TrackStatusView: View {
    let controller: TrackController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(
                        L10n.format(
                            "Found %@ files · Checked %@ folders", String(controller.files.count),
                            String(controller.foldersScanned)))
                    Spacer()
                    Button(L10n.text("Stop search")) { controller.cancelScan() }
                }
            }
            if controller.unreadableFolders > 0 {
                Text(L10n.text("Some folders could not be read. Try choosing the folder again."))
            }
            if let message = controller.message {
                HStack(alignment: .top) {
                    Text(message).foregroundStyle(Palette.flame)
                    Spacer()
                    Button {
                        controller.message = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss"))
                }
            }
        }.font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
    }
}
