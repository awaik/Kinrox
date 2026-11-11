import RemoteProtocol
import SwiftUI

/// Figma 205:4347 (`12 · Remote — Similar`): the deck row below the switches.
struct MusicSimilarControl: View {
    @Bindable var store: RemoteAppModel

    var body: some View {
        if store.similarActive {
            MusicSimilarBanner(store: store, offersNotInterested: true)
        } else if store.similarFinding {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("Looking for similar music…")).lineLimit(1)
            }
            .font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
            .accessibilityElement(children: .combine)
        } else {
            Button {
                store.setSimilar(true)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "infinity").font(.system(size: 14, weight: .semibold))
                    Text(L10n.text("Listen to similar")).font(.system(size: 14, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
            }
            .buttonStyle(.plain).disabled(!store.canStartSimilar)
            .opacity(store.canStartSimilar ? 1 : 0.4)
        }
    }
}

/// Active Similar: deck variant offers Not interested; the queue variant only stops.
struct MusicSimilarBanner: View {
    @Bindable var store: RemoteAppModel
    let offersNotInterested: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "infinity").font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
            Text(L10n.text("Adding similar tracks as you listen"))
                .font(.system(size: 14, weight: .medium)).lineLimit(2).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            if offersNotInterested, let track = store.state.music?.track {
                MusicNotInterestedMenu(store: store, track: track) {
                    Image(systemName: "hand.thumbsdown").font(.system(size: 16))
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
            }
            Button(L10n.text("Stop")) { store.setSimilar(false) }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                .frame(minWidth: 44, minHeight: 36)
                .accessibilityLabel(L10n.text("Stop adding similar tracks"))
                .disabled(store.similarRequestPending)
        }
        .buttonStyle(.plain).foregroundStyle(Palette.flame)
        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(minHeight: 44)
        .background(Palette.ember.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.flame.opacity(0.4)))
        .disabled(!store.controlsEnabled)
    }
}

struct MusicNotInterestedMenu<Label: View>: View {
    @Bindable var store: RemoteAppModel
    let track: RemoteMusicTrack
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            MusicNotInterestedItems(store: store, track: track)
        } label: {
            label()
        }
        .accessibilityLabel(L10n.text("Not interested in this track"))
    }
}

struct MusicNotInterestedItems: View {
    @Bindable var store: RemoteAppModel
    let track: RemoteMusicTrack

    var body: some View {
        Button(L10n.text("Not interested in this track")) {
            store.hideFromSimilar(track, scope: .track)
        }
        if let artist = track.artists.first, !artist.isEmpty {
            Button(L10n.format("Not interested in %@", artist)) {
                store.hideFromSimilar(track, scope: .artist)
            }
        }
    }
}

struct MusicSimilarFeedbackView: View {
    @Bindable var store: RemoteAppModel
    let feedback: SimilarHiddenFeedback

    var body: some View {
        HStack(spacing: 12) {
            Text(feedback.text).font(.system(size: 13)).foregroundStyle(Palette.textPrimary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
            Button(L10n.text("Undo")) { store.undoHiddenFromSimilar() }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.flame)
                .buttonStyle(.plain).frame(minHeight: 32)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
    }
}
