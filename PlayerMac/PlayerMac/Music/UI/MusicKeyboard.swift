import AppKit
import MusicCore
import SwiftUI

/// Window-scoped keyboard handling leaves field editors, sheets and menus to AppKit.
struct MusicKeyboard: NSViewRepresentable {
    let model: MusicViewModel
    let enabled: Bool

    func makeNSView(context: Context) -> KeyboardView { KeyboardView(model: model) }
    func updateNSView(_ view: KeyboardView, context: Context) { view.enabled = enabled }

    /// Command shortcuts keep their physical key on non-Latin layouts, as AppKit menus do.
    static func matchesKey(_ event: NSEvent, character: String, keyCode: UInt16) -> Bool {
        let text = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if text == character { return true }
        return event.keyCode == keyCode && text.unicodeScalars.contains { !$0.isASCII }
    }

    @MainActor final class KeyboardView: NSView {
        let model: MusicViewModel
        var enabled = true
        private var monitor: Any?

        init(model: MusicViewModel) {
            self.model = model
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) == true }
                return consumed ? nil : event
            }
        }

        required init?(coder: NSCoder) { nil }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        func handle(_ event: NSEvent) -> Bool {
            guard enabled, let window, event.window === window, window.isKeyWindow,
                window.attachedSheet == nil
            else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags == .command, MusicKeyboard.matchesKey(event, character: "f", keyCode: 3) {
                model.searchRequested = true
                return true
            }
            if event.keyCode == 53, model.hasActivePopover {
                model.dismissPopovers()
                return true
            }
            guard !(window.firstResponder is NSTextView), !model.isSearching,
                !model.hasActivePopover
            else { return false }
            if flags == .command, MusicKeyboard.matchesKey(event, character: "z", keyCode: 6) {
                model.undo()
                return true
            }
            if event.keyCode == 48, flags.isEmpty || flags == .shift {
                model.focusedColumn =
                    MusicViewModel.Column(
                        rawValue: (model.focusedColumn.rawValue + (flags == .shift ? 2 : 1)) % 3)
                    ?? .tracks
                return true
            }
            guard flags.isEmpty else { return false }
            switch event.keyCode {
            case 49:
                // A focused SwiftUI button can consume Space before the menu shortcut.
                if !event.isARepeat, model.canTogglePause { model.togglePause() }
            case 53:
                if model.leftSection != .home {
                    model.collapseLeftSection()
                } else {
                    model.leaveSearch()
                }
            case 36, 76: model.playFocused()
            case 51, 117:
                if model.isQueue, let id = model.focusedQueueID { model.removeFromQueue(id) }
            case 123:
                model.focusedColumn =
                    MusicViewModel.Column(rawValue: max(0, model.focusedColumn.rawValue - 1))
                    ?? .source
            case 124:
                model.focusedColumn =
                    MusicViewModel.Column(rawValue: min(2, model.focusedColumn.rawValue + 1))
                    ?? .tracks
            case 125: model.moveFocus(by: 1)
            case 126: model.moveFocus(by: -1)
            default:
                guard MusicKeyboard.matchesKey(event, character: "l", keyCode: 37) else {
                    return false
                }
                model.likeFocused()
            }
            return true
        }
    }
}

extension MusicViewModel {
    func playFocused() {
        guard canPlayLibrary else { return }
        if focusedColumn == .albums, let album {
            playAlbum(album)
            return
        }
        if isQueue {
            if let index = queue.items.firstIndex(where: { $0.id == focusedQueueID }) {
                play(queue.items.map(\.track), at: index)
            }
        } else if let index = contents.tracks.firstIndex(where: { $0.id == focusedTrackID }) {
            play(contents.tracks, at: index)
        }
    }

    func likeFocused() {
        if focusedColumn == .albums, let album {
            toggleAlbum(album)
            return
        }
        if focusedColumn == .source, case .artist(let id) = selection.source,
            let artist = catalog.artists.first(where: { $0.id == id })
        {
            toggleArtist(artist)
            return
        }
        if isQueue, let item = queue.items.first(where: { $0.id == focusedQueueID }) {
            toggleTrack(item.track, anchor: item.id.uuidString)
        } else if let index = contents.tracks.firstIndex(where: { $0.id == focusedTrackID }) {
            let track = contents.tracks[index]
            // Discovery rows anchor their favorite popover by track ID.
            toggleTrack(
                track,
                anchor: selection.source == .similar ? "discovery-\(track.id)" : "track-\(index)")
        }
    }

    func moveFocus(by step: Int) {
        switch focusedColumn {
        case .source:
            let sources: [MusicSource] =
                (query.isEmpty ? [] : [.search(query)]) + [.liked, .albums, .similar, .queue]
                + library.playlists.map { .playlist($0.id) }
                + catalog.artists.filter { !$0.isVariousArtists }.map { .artist($0.id) }
            let index = sources.firstIndex(of: selection.source) ?? 0
            select(sources[min(max(0, index + step), sources.count - 1)])
        case .albums:
            let albums = sortedAlbums
            guard !albums.isEmpty else { return }
            let index = albums.firstIndex { $0.id == selection.albumID } ?? -1
            selectAlbum(albums[min(max(0, index + step), albums.count - 1)].id)
        case .tracks:
            if isQueue {
                let items = queue.items
                guard !items.isEmpty else { return }
                let index = items.firstIndex { $0.id == focusedQueueID } ?? -1
                focusedQueueID = items[min(max(0, index + step), items.count - 1)].id
            } else {
                guard !contents.tracks.isEmpty else { return }
                let index = contents.tracks.firstIndex { $0.id == focusedTrackID } ?? -1
                let nextID =
                    contents.tracks[min(max(0, index + step), contents.tracks.count - 1)].id
                focusTrack(nextID)
            }
        }
    }
}
