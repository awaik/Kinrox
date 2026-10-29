import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TrackScopeView: View {
    let controller: TrackController
    @State private var root: URL
    @State private var recursive: Bool
    @State private var remember: Bool

    init(controller: TrackController) {
        self.controller = controller
        let settings = controller.settings ?? TrackFolderSettings(root: URL(fileURLWithPath: "/"))
        _root = State(initialValue: settings.root)
        _recursive = State(initialValue: settings.recursive)
        _remember = State(initialValue: settings.remember)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                TrackPanelHeader(title: L10n.text("Search folder")) {
                    controller.presentation = .quick
                }
                Text(
                    L10n.text("Choose a common folder containing your video, audio and subtitles.")
                )
                .font(KinroxFont.body).foregroundStyle(Palette.textSecondary)
                HStack(spacing: 16) {
                    Image(systemName: "folder").font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(root.lastPathComponent).font(KinroxFont.bodyStrong)
                        Text(root.path).font(KinroxFont.caption).foregroundStyle(
                            Palette.textSecondary
                        )
                        .lineLimit(2).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("Change…")) {
                        TrackFilePanels.chooseFolder(controller, initial: root) { root = $0 }
                    }.buttonStyle(.bordered)
                }.padding(18).background(Palette.glass, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $recursive) {
                        Text(L10n.text("Search subfolders")).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).tint(Palette.ember)
                    Text(L10n.text("All levels inside the selected folder."))
                        .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $remember) {
                        Text(L10n.text("Remember selection for this folder"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).tint(Palette.ember)
                    Text(
                        L10n.text(
                            "Keep language, release group and subtitle preferences for the next episode."
                        )
                    )
                    .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
                }
                HStack {
                    Spacer()
                    Button(L10n.text("Cancel")) { controller.presentation = .quick }.buttonStyle(
                        .bordered)
                    Button(L10n.text("Done")) {
                        controller.applySettings(
                            root: root, recursive: recursive, remember: remember)
                        controller.presentation = .quick
                    }.buttonStyle(.borderedProminent).tint(Palette.ember)
                }.padding(.top, 20)
            }.padding(24).font(KinroxFont.bodyStrong).foregroundStyle(Palette.textPrimary)
                .disabled(controller.isChoosingFile)
        }
    }
}

@MainActor
enum TrackFilePanels {
    static func openTrack(_ controller: TrackController, kind: MediaTrackKind? = nil) {
        let kind = kind ?? controller.selectedKind
        guard controller.isReady, !controller.isChoosingFile, let window = NSApp.keyWindow else {
            return
        }
        let panel = NSOpenPanel()
        panel.title =
            kind == .audio ? L10n.text("Add Audio File…") : L10n.text("Add Subtitle File…")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let extensions =
            kind == .audio ? TrackFileScanner.audioExtensions : TrackFileScanner.subtitleExtensions
        panel.allowedContentTypes = extensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = controller.settings?.root
        controller.presentFilePanel(panel, for: window) { [weak controller] url in
            controller?.addFile(url, kind: kind)
        }
    }

    static func chooseFolder(
        _ controller: TrackController, initial: URL, selected: @escaping (URL) -> Void
    ) {
        guard !controller.isChoosingFile, let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Search folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initial
        controller.presentFilePanel(panel, for: window, selected: selected)
    }
}

struct TrackPanelsOverlay: View {
    @Bindable var controller: TrackController

    var body: some View {
        GeometryReader { geometry in
            let quick = controller.presentation == .quick
            let width = min(
                quick ? 480 : controller.presentation == .scope ? 640 : 960,
                geometry.size.width - 40)
            let height = min(
                controller.presentation == .scope ? 500 : 560, geometry.size.height - 60)
            ZStack(alignment: quick ? .topTrailing : .center) {
                Color.black.opacity(quick ? 0.001 : 0.22)
                    .contentShape(Rectangle()).onTapGesture { controller.presentation = nil }
                Group {
                    switch controller.presentation {
                    case .quick: TrackSelectionView(controller: controller)
                    case .browser: TrackBrowserView(controller: controller)
                    case .scope: TrackScopeView(controller: controller)
                    case nil: EmptyView()
                    }
                }
                .frame(width: width, height: height)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20).strokeBorder(
                        Palette.strokeGlass, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 32, y: 16)
                .padding(.top, quick ? 40 : 0).padding(.trailing, quick ? 24 : 0)
            }
        }
        .onExitCommand { controller.presentation = nil }
    }
}
