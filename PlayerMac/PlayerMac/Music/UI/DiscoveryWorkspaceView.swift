import MusicCore
import SwiftUI

/// Similar & discovery workspace (Figma page 11 · Spotify — Discovery v4).
struct DiscoveryWorkspaceView: View {
    @Bindable var model: MusicViewModel
    @State private var hiddenNotice: String?
    @State private var noticeToken = 0

    private var snapshot: MusicDiscoverySnapshot? { model.discoverySnapshot }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverySeedHeader(model: model, snapshot: snapshot)
            DiscoveryControls(model: model, snapshot: snapshot)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            MusicServiceStatus(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    DiscoveryStatusLine(model: model, snapshot: snapshot)
                    results
                    if let snapshot, !snapshot.mixes.isEmpty {
                        DiscoveryMixesStrip(model: model, mixes: snapshot.mixes)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
        }
        .background(Palette.canvas)
        .overlay(alignment: .bottom) {
            if let hiddenNotice {
                DiscoveryUndoToast(message: hiddenNotice) {
                    model.undoNotInterested()
                    self.hiddenNotice = nil
                }
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: hiddenNotice)
        .task(id: noticeToken) {
            guard hiddenNotice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { hiddenNotice = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Similar & discovery"))
    }

    @ViewBuilder
    private var results: some View {
        let sections = snapshot?.sections.filter { !$0.items.isEmpty } ?? []
        // Rows are numbered, played and queued in the order they are shown.
        let visible = snapshot?.displayItems ?? []
        let numbering = Dictionary(
            visible.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        ForEach(sections) { section in
            DiscoverySectionHeader(kind: section.kind, count: section.items.count) {
                model.play(section.items.map(\.track))
            }
            ForEach(section.items) { item in
                DiscoveryTrackRow(
                    model: model, item: item, number: numbering[item.id] ?? 0,
                    play: {
                        let index = visible.firstIndex { $0.id == item.id } ?? 0
                        model.play(visible.map(\.track), at: index)
                    },
                    hide: { notice in
                        hiddenNotice = notice
                        noticeToken += 1
                    })
            }
        }
        if model.isDiscovering, model.listenBrainzStatus == .ready,
            !sections.contains(where: { $0.kind == .listeners })
        {
            DiscoverySectionHeader(kind: .listeners, count: nil, loading: true, playSection: nil)
            DiscoverySkeletonRows(count: 3)
        } else if model.isDiscovering, sections.isEmpty {
            DiscoverySkeletonRows(count: 6)
        }
        if !model.isDiscovering, sections.isEmpty {
            DiscoveryEmptyState(hideLiked: model.discoveryHideLiked)
        }
    }
}

/// One-line source and progress summary above the results.
struct DiscoveryStatusLine: View {
    @Bindable var model: MusicViewModel
    let snapshot: MusicDiscoverySnapshot?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var dotColor: Color {
        if model.isDiscovering { return Palette.flame }
        return model.listenBrainzStatus == .unavailable ? Palette.textTertiary : Palette.online
    }

    /// Plain wording: sources are explained in Settings → Spotify, not on this screen.
    private var text: String {
        if model.isDiscovering { return L10n.text("Looking for similar music…") }
        let count = (snapshot?.items.count ?? 0).formatted()
        if model.listenBrainzStatus == .unavailable {
            return L10n.format(
                "%@ tracks · Recommendations from other listeners are unavailable right now", count)
        }
        return L10n.format("%@ tracks", count)
    }
}

struct DiscoverySectionHeader: View {
    let kind: MusicDiscoverySectionKind
    let count: Int?
    var loading = false
    let playSection: (() -> Void)?

    init(
        kind: MusicDiscoverySectionKind, count: Int?, loading: Bool = false,
        playSection: (() -> Void)?
    ) {
        self.kind = kind
        self.count = count
        self.loading = loading
        self.playSection = playSection
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
            if loading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            if let count {
                Text(count.formatted())
                    .font(KinroxFont.monoDigits(11))
                    .foregroundStyle(Palette.textTertiary)
            }
            if let playSection {
                Button(action: playSection) {
                    HStack(spacing: 4) {
                        MusicIcon(name: "MusicPlay", size: 8)
                        Text(L10n.text("Play section"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Palette.flame)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        switch kind {
        case .listeners: L10n.text("Listened together")
        case .collaborators: L10n.text("Collaborators & remixers")
        case .yourPlaylists: L10n.text("From your library")
        case .genre: L10n.text("Same genre")
        }
    }
}
