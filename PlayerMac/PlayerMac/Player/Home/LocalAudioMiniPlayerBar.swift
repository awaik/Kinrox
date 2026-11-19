import MusicCore
import SwiftUI

struct LocalAudioMiniPlayerBar: View {
    let player: LocalAudioViewModel
    @State private var showQueue = false

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(KinroxFont.bodyStrong).lineLimit(1)
                    Text(
                        [track.artist, track.album, track.format].filter { !$0.isEmpty }.joined(
                            separator: " · ")
                    )
                    .foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: 240, alignment: .leading)
                transport
                LocalAudioScrubber(player: player).frame(minWidth: 64, maxWidth: .infinity)
                HomeRatingBadge(rating: track.rating)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2")
                    MusicSlider(
                        value: player.volume, range: 0...100, label: L10n.text("Volume"), step: 5
                    ) {
                        player.setVolume($0)
                    }.frame(width: 58)
                }
                HomePill(
                    title: L10n.format("Queue · %@", player.queue.upcoming.count.formatted()),
                    icon: "list.bullet"
                ) { showQueue.toggle() }
                .popover(isPresented: $showQueue, arrowEdge: .top) {
                    LocalAudioQueuePopover(player: player)
                }
            }
            .font(KinroxFont.caption)
            .padding(.horizontal, 14)
            .frame(height: 68)
            .kinroxGlass(in: Rectangle())
            .background(Palette.elevated)
            .tint(Palette.ember)
            .accessibilityIdentifier("local-audio-mini-player")
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Palette.glassStrong)
            if let data = player.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "waveform").foregroundStyle(Palette.flame)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var transport: some View {
        HStack(spacing: 9) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(!player.canPrevious).accessibilityLabel(L10n.text("Previous track"))
            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.paused ? "play.fill" : "pause.fill")
                    .frame(width: 32, height: 32)
                    .background(Palette.ember, in: Circle())
            }
            .accessibilityLabel(player.paused ? L10n.text("Play") : L10n.text("Pause"))
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!player.canNext).accessibilityLabel(L10n.text("Next track"))
        }
        .buttonStyle(.plain)
    }
}

private struct LocalAudioScrubber: View {
    let player: LocalAudioViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text(TimeFormat.string(player.displayedPosition)).lineLimit(1).monospacedDigit()
            MusicSlider(
                value: player.displayedPosition, range: 0...max(1, player.duration),
                label: L10n.text("Playback position"), step: 5
            ) { player.seek($0) }
            .disabled(player.loading || player.duration <= 0)
            Text("−" + TimeFormat.string(max(0, player.duration - player.displayedPosition)))
                .lineLimit(1).monospacedDigit().foregroundStyle(Palette.textSecondary)
        }
        .font(KinroxFont.time)
    }
}

struct LocalAudioQueuePopover: View {
    let player: LocalAudioViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("Queue")).font(KinroxFont.title)
                Spacer()
                HomePill(
                    title: L10n.text("Shuffle"), icon: "shuffle", prominent: player.queue.shuffled
                ) {
                    player.toggleShuffle()
                }
                HomePill(
                    title: repeatTitle,
                    icon: player.queue.repeatMode == .one ? "repeat.1" : "repeat",
                    prominent: player.queue.repeatMode != .off
                ) {
                    player.cycleRepeat()
                }
            }
            if player.queue.upcoming.isEmpty {
                Text(L10n.text("Queue is empty")).foregroundStyle(Palette.textSecondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(player.queue.upcoming) { item in
                            HStack {
                                Button {
                                    player.jump(to: item.id)
                                } label: {
                                    Label(player.title(for: item.track), systemImage: "play.fill")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Menu {
                                    Button(L10n.text("Move up")) { player.move(item.id, by: -1) }
                                    Button(L10n.text("Move down")) { player.move(item.id, by: 1) }
                                    Button(L10n.text("Remove from queue"), role: .destructive) {
                                        player.remove(item.id)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuIndicator(.hidden).fixedSize()
                            }.padding(6)
                        }
                    }
                }.frame(maxHeight: 270)
            }
        }
        .padding(14)
        .frame(width: 370)
        .background(Palette.elevated)
    }

    private var repeatTitle: String {
        switch player.queue.repeatMode {
        case .off: L10n.text("Repeat")
        case .all: L10n.text("Repeat all")
        case .one: L10n.text("Repeat one")
        }
    }
}
