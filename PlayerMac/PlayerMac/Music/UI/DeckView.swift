import AppKit
import MusicCore
import Observation
import SwiftUI

struct DeckView: View {
    @Bindable var model: MusicViewModel
    let compact: Bool
    var width: CGFloat = 1440
    @State private var clock = MusicDisplayClock()
    @State private var windowVisible = true

    var body: some View {
        deck
            .background(
                DeckWindowObserver { visible in
                    if windowVisible != visible {
                        windowVisible = visible
                    }
                    if visible {
                        clock.sync(model.displayedPosition)
                    }
                }
            )
            .task(id: ClockTaskKey(paused: model.paused, visible: windowVisible)) {
                clock.sync(model.displayedPosition)
                guard !model.paused, windowVisible else { return }
                do {
                    while !Task.isCancelled {
                        let current = max(0, model.displayedPosition)
                        clock.sync(current)
                        let fraction = current.truncatingRemainder(dividingBy: 1)
                        let delayMs = Int(((1.0 - fraction) * 1000).rounded(.up)) + 15
                        try await Task.sleep(for: .milliseconds(max(50, min(1000, delayMs))))
                        clock.sync(model.displayedPosition)
                    }
                } catch {
                    // Pausing, occluding the window, or leaving Music cancels the clock.
                }
            }
            .onChange(of: model.position) { _, _ in clock.sync(model.displayedPosition) }
    }

    private var deck: some View {
        HStack(spacing: compact ? 24 : 26) {
            display.frame(width: compact ? 408 : min(480, width * 0.32), height: 98)
            VStack(spacing: 14) {
                HStack(spacing: 7) {
                    transport
                    MusicSwitch(
                        title: L10n.text("Shuffle"), enabled: model.queue.shuffled,
                        action: model.shuffle
                    ).disabled(!model.canShuffle)
                    MusicSwitch(
                        title: L10n.text("Repeat"), enabled: model.queue.repeatMode != .off,
                        value: repeatValue, action: model.cycleRepeat
                    ).disabled(!model.canRepeat)
                    Spacer(minLength: 0)
                    if let track = model.currentTrack {
                        TrackHeart(model: model, track: track, anchor: "deck", labeled: true)
                    }
                    if !compact {
                        Text(model.outputName).font(.system(size: 11)).foregroundStyle(
                            Palette.textTertiary)
                        MusicActionButton(title: L10n.text("Queue"), symbol: "list.bullet") {
                            model.select(.queue)
                        }
                    }
                }
                HStack(spacing: 12) {
                    MusicClockText(clock: clock, paused: model.paused, position: model.position)
                        .frame(width: 36, height: 16)
                    MusicClockSlider(clock: clock, model: model)
                    MusicClockText(
                        clock: clock, paused: model.paused, position: model.position,
                        remaining: model.currentTrack?.duration ?? 0
                    )
                    .frame(width: 42, height: 16)
                    Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true)
                    MusicSlider(
                        value: model.volume, range: 0...100, label: L10n.text("Volume"), step: 5,
                        valueKnown: model.volumeKnown
                    ) { model.setVolume($0) }.disabled(!model.canAdjustVolume)
                        .frame(width: compact ? 90 : 130).tint(Palette.textPrimary)
                        .accessibilityLabel(L10n.text("Volume"))
                    Text(model.volumeKnown ? Int(model.volume).formatted() : "—").frame(width: 28)
                }.font(KinroxFont.monoDigits(12)).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 20).frame(height: 124)
        .background(Palette.elevated)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var display: some View {
        let clockColumnWidth = compact ? 142 : min(168, width * 0.11)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    MusicIcon(name: model.paused ? "MusicPause" : "MusicPlay", size: 10)
                    MusicClockText(clock: clock, paused: model.paused, position: model.position)
                        .font(
                            KinroxFont.monoDigits(compact ? 34 : 38)
                        )
                        .tracking(-2).minimumScaleFactor(0.7).lineLimit(1)
                        .frame(
                            width: max(0, clockColumnWidth - 16), height: 40, alignment: .leading)
                }.foregroundStyle(Palette.flame)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<24) { index in
                        Rectangle().fill(Palette.ember)
                            .frame(
                                height: model.paused ? 3 : CGFloat(4 + (index * 7) % 20))
                    }
                }.frame(height: 20, alignment: .bottom).accessibilityHidden(true)
            }.frame(width: clockColumnWidth, alignment: .leading)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if model.currentTrack?.explicit == true { SpotifyExplicitBadge() }
                    Text(model.currentTrack?.title ?? "—").help(model.currentTrack?.title ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
                if let track = model.currentTrack {
                    TrackArtistLink(
                        model: model, track: track, anchor: "deck-artist",
                        font: .system(size: 12))
                    TrackAlbumLink(
                        model: model, track: track, anchor: "deck-album",
                        font: .system(size: 12))
                } else {
                    Text("—")
                    Text("—")
                }
                Text(L10n.format("Next: %@", model.nextTrack?.title ?? "—")).help(
                    model.nextTrack.map {
                        $0.title + " — " + $0.artistNames + " — " + $0.albumTitle
                    } ?? ""
                )
                .foregroundStyle(Palette.textTertiary)
            }.font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16).background(.black, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
        .contextMenu {
            if let track = model.currentTrack {
                if let artist = track.artists.first {
                    Button(L10n.text("Go to artist")) { model.navigateToArtist(artist) }
                }
                if !track.albumID.isEmpty {
                    Button(L10n.text("Go to album")) {
                        model.navigateToAlbum(albumID: track.albumID, trackID: track.id)
                    }
                }
                Divider()
                SpotifyContentLink(kind: "track", id: track.id)
                SpotifyContentLink(
                    kind: "album", id: track.albumID, title: L10n.text("Open album in Spotify"))
            }
        }.accessibilityElement(children: .contain)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportButton(
                "MusicPrev", L10n.text("Previous track"), model.previous,
                enabled: model.canPrevious)
            Divider().frame(height: 34)
            transportButton(
                model.paused ? "MusicPlay" : "MusicPause",
                model.paused ? L10n.text("Play") : L10n.text("Pause"), model.togglePause,
                enabled: model.canTogglePause, active: !model.paused)
            Divider().frame(height: 34)
            transportButton("MusicStop", L10n.text("Stop"), model.stop, enabled: model.canStop)
            Divider().frame(height: 34)
            transportButton(
                "MusicNext", L10n.text("Next track"), model.next, enabled: model.canNext)
        }.background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
    }

    private func transportButton(
        _ icon: String, _ title: String, _ action: @escaping () -> Void,
        enabled: Bool, active: Bool = false
    ) -> some View {
        Button(action: action) {
            MusicIcon(name: icon, size: 14).frame(width: compact ? 38 : 46, height: 36)
                .foregroundStyle(active ? Palette.ember : Palette.textPrimary).contentShape(
                    Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
            .disabled(!enabled)
    }

    private var repeatValue: String {
        switch model.queue.repeatMode {
        case .off: L10n.text("Off")
        case .all: L10n.text("Repeat all")
        case .one: L10n.text("Repeat one")
        }
    }
}

private struct ClockTaskKey: Equatable {
    let paused: Bool
    let visible: Bool
}

struct DeckWindowObserver: NSViewRepresentable {
    let onVisibilityChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onVisibilityChange: onVisibilityChange)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onVisibilityChange = onVisibilityChange
    }

    @MainActor final class ObserverView: NSView {
        var onVisibilityChange: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onVisibilityChange: @escaping (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reportVisibility()
                    }
                }
            }
            reportVisibility()
        }

        func reportVisibility() {
            guard let window else {
                onVisibilityChange(false)
                return
            }
            onVisibilityChange(window.isVisible && window.occlusionState.contains(.visible))
        }
    }
}

/// Only the time labels and scrubber observe ticks; the rest of the deck stays unchanged.
@MainActor @Observable
final class MusicDisplayClock {
    var position: Double = 0
    @ObservationIgnored private(set) var updates = 0

    func sync(_ rawPosition: Double) {
        let wholeSecond = rawPosition.isFinite ? max(0, rawPosition.rounded(.down)) : 0
        if position != wholeSecond {
            position = wholeSecond
            updates += 1
        }
    }
}

private struct MusicClockText: View {
    let clock: MusicDisplayClock
    let paused: Bool
    let position: Double
    var remaining: Double?

    var body: some View {
        let value =
            paused ? (position.isFinite ? max(0, position.rounded(.down)) : 0) : clock.position
        Text(
            remaining.map { TimeFormat.remaining(position: value, duration: $0) }
                ?? TimeFormat.string(value))
    }
}

private struct MusicClockSlider: View {
    let clock: MusicDisplayClock
    let model: MusicViewModel

    var body: some View {
        MusicSlider(
            value: model.paused ? model.position : clock.position,
            range: 0...max(1, model.currentTrack?.duration ?? 1),
            label: L10n.text("Playback position"), step: 10
        ) { model.seek($0) }.tint(Palette.ember).disabled(!model.canSeek)
    }
}
