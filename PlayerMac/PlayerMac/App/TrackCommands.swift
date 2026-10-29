import SwiftUI

struct TrackCommands: Commands {
    let session: PlayerSession
    var body: some Commands {
        CommandMenu(L10n.text("Audio")) {
            TrackMenuContent(session: session, kind: .audio)
        }
        CommandMenu(L10n.text("Subtitles")) {
            TrackMenuContent(session: session, kind: .subtitle)
        }
    }
}

private struct TrackMenuContent: View {
    let session: PlayerSession
    let kind: MediaTrackKind
    private var controller: TrackController? { session.model?.trackController }
    private var enabled: Bool {
        controller?.isReady == true && controller?.isChoosingFile == false
            && !session.isOpenPanelShown && session.pairing.prompt == nil
    }

    var body: some View {
        Group {
            Button(L10n.text("Audio & Subtitles")) {
                controller?.selectedKind = kind
                controller?.presentation = .quick
            }
            Divider()
            if kind == .subtitle {
                Toggle(
                    L10n.text("Off"),
                    isOn: Binding(
                        get: {
                            !(controller?.available(.subtitle).contains(where: \.isSelected)
                                ?? false)
                        },
                        set: { if $0 { controller?.disableSubtitles() } }))
            }
            ForEach(controller?.available(kind) ?? []) { track in
                Toggle(
                    track.displayTitle,
                    isOn: Binding(
                        get: { track.isSelected }, set: { if $0 { controller?.select(track) } })
                )
                .help(track.detail(relativeTo: controller?.settings?.root))
            }
            ForEach(controller?.matchingFiles(kind) ?? []) { file in
                Button(file.title) { controller?.select(file) }.help(file.relativePath)
            }
            Divider()
            Button(kind == .audio ? L10n.text("Next Audio Track") : L10n.text("Next Subtitles")) {
                controller?.cycle(kind)
            }.keyboardShortcut(kind == .audio ? "a" : "s", modifiers: [.control, .command])
            Button(kind == .audio ? L10n.text("Add Audio File…") : L10n.text("Add Subtitle File…"))
            {
                if let controller { TrackFilePanels.openTrack(controller, kind: kind) }
            }
            Button(L10n.text("All files in folder")) { controller?.presentation = .browser }
            Button(L10n.text("Choose search folder…")) { controller?.presentation = .scope }
            Divider()
            Toggle(
                L10n.text("Remember selection for this folder"),
                isOn: Binding(
                    get: { controller?.settings?.remember ?? true },
                    set: { controller?.setRemember($0) }))
        }.disabled(!enabled)
    }
}
