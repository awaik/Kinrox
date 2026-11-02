import MusicCore
import SwiftUI

struct DeckView: View {
    @Bindable var model: MusicViewModel
    let compact: Bool
    var width: CGFloat = 1440

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: model.paused)) { _ in deck }
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
                    ).disabled(!model.allows("toggling_shuffle"))
                    MusicSwitch(
                        title: L10n.text("Repeat"), enabled: model.queue.repeatMode != .off,
                        value: repeatValue, action: model.cycleRepeat
                    ).disabled(
                        !model.allows(
                            model.queue.repeatMode == .all || model.queue.repeatMode == .one
                                ? "toggling_repeat_track" : "toggling_repeat_context"))
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
                    Text(TimeFormat.string(model.displayedPosition)).frame(width: 36)
                    MusicSlider(
                        value: model.displayedPosition,
                        range: 0...max(1, model.currentTrack?.duration ?? 1),
                        label: L10n.text("Playback position"), step: 10
                    ) { model.seek($0) }.tint(Palette.ember).disabled(!model.allows("seeking"))
                    Text(
                        TimeFormat.remaining(
                            position: model.displayedPosition,
                            duration: model.currentTrack?.duration ?? 0)
                    )
                    .frame(width: 42)
                    Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true)
                    MusicSlider(
                        value: model.volume, range: 0...100, label: L10n.text("Volume"), step: 5
                    ) { model.setVolume($0) }.disabled(!model.allows("volume"))
                        .frame(width: compact ? 90 : 130).tint(Palette.textPrimary)
                        .accessibilityLabel(L10n.text("Volume"))
                    Text(Int(model.volume).formatted()).frame(width: 28)
                }.font(KinroxFont.monoDigits(12)).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 20).frame(height: 124)
        .background(Palette.elevated)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var display: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    MusicIcon(name: model.paused ? "MusicPause" : "MusicPlay", size: 10)
                    Text(TimeFormat.string(model.displayedPosition)).font(
                        KinroxFont.monoDigits(compact ? 34 : 38)
                    )
                    .tracking(-2).minimumScaleFactor(0.7).lineLimit(1)
                }.foregroundStyle(Palette.flame)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<24) { index in
                        Rectangle().fill(Palette.ember)
                            .frame(
                                height: model.paused ? 3 : CGFloat(4 + (index * 7) % 20))
                    }
                }.frame(height: 20, alignment: .bottom).accessibilityHidden(true)
            }.frame(width: compact ? 142 : min(168, width * 0.11), alignment: .leading)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if model.currentTrack?.explicit == true { SpotifyExplicitBadge() }
                    Text(model.currentTrack?.title ?? "—").help(model.currentTrack?.title ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
                Text(model.currentTrack?.artistNames ?? "—").help(
                    model.currentTrack?.artistNames ?? "")
                Text(model.currentTrack?.albumTitle ?? "—").help(
                    model.currentTrack?.albumTitle ?? "")
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
                SpotifyContentLink(kind: "track", id: track.id)
                SpotifyContentLink(
                    kind: "album", id: track.albumID, title: L10n.text("Open album in Spotify"))
            }
        }.accessibilityElement(children: .combine)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("MusicPrev", L10n.text("Previous track"), model.previous)
            Divider().frame(height: 34)
            transportButton(
                model.paused ? "MusicPlay" : "MusicPause",
                model.paused ? L10n.text("Play") : L10n.text("Pause"), model.togglePause,
                active: !model.paused)
            Divider().frame(height: 34)
            transportButton("MusicStop", L10n.text("Stop"), model.stop)
            Divider().frame(height: 34)
            transportButton("MusicNext", L10n.text("Next track"), model.next)
        }.background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
    }

    private func transportButton(
        _ icon: String, _ title: String, _ action: @escaping () -> Void,
        active: Bool = false
    ) -> some View {
        Button(action: action) {
            MusicIcon(name: icon, size: 14).frame(width: compact ? 38 : 46, height: 36)
                .foregroundStyle(active ? Palette.ember : Palette.textPrimary).contentShape(
                    Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
            .disabled(
                !model.allows(
                    icon == "MusicNext"
                        ? "skipping_next"
                        : icon == "MusicPrev"
                            ? "skipping_prev" : icon == "MusicPlay" ? "resuming" : "pausing")
                    || (icon == "MusicStop" && !model.allows("seeking")))
    }

    private var repeatValue: String {
        switch model.queue.repeatMode {
        case .off: L10n.text("Off")
        case .all: L10n.text("Repeat all")
        case .one: L10n.text("Repeat one")
        }
    }
}
