import AppKit
import SwiftUI

/// Empty window: welcome screen to open video and recents.
struct WelcomeView: View {
    let recents: RecentFilesStore?
    let actions: PlayerActions
    var remote: RemoteServer? = nil
    var connectPhone: () -> Void = {}
    @State private var showsAll = false

    private static let collapsedCount = 4
    private static let cardWidth: CGFloat = 240
    private static let cardSpacing: CGFloat = 24
    private var items: [RecentItem] { recents?.items ?? [] }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Palette.base
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Palette.ember.opacity(0.34), Palette.ember.opacity(0)],
                            center: .center, startRadius: 0, endRadius: 460)
                    )
                    .frame(width: 920, height: 540)
                    .blur(radius: 50)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(y: -300)
                    .allowsHitTesting(false)
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        if !items.isEmpty {
                            recentSection(width: geometry.size.width - 80)
                                .padding(.top, 64)
                        }
                        Text(L10n.text("Space — pause   ·   ← → — 5s   ·   F — full screen"))
                            .font(KinroxFont.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.top, 56)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 72)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.never)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let remote {
                RemoteStatusView(text: remote.welcomeStatus, online: remote.isOnline)
                    .padding(.top, 14).padding(.trailing, 20)
            }
        }
        .onAppear { recents?.refreshAvailability() }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            Image("KinroxLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Palette.ember.opacity(0.35), radius: 24, y: 16)
                .accessibilityHidden(true)
            Text(L10n.text("What are we watching?"))
                .font(KinroxFont.display())
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(
                L10n.text(
                    "Drop video into window or open a file. MKV, MP4, MOV, WebM — ready to play.")
            )
            .font(KinroxFont.body)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                openButton
                if remote != nil {
                    RemotePillButton(
                        title: L10n.text("Connect iPhone"), icon: "wifi", action: connectPhone)
                }
            }
        }
    }

    private var openButton: some View {
        Button(action: actions.openFile) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                Text(L10n.text("Open File"))
                Text("⌘O")
                    .font(KinroxFont.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.22), in: Capsule())
            }
            .font(KinroxFont.bodyStrong)
            .foregroundStyle(Palette.textPrimary)
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
            .background(Palette.emberGradient, in: Capsule())
            .emberGlow(radius: 18, opacity: 0.45, y: 10)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .padding(.top, 4)
    }

    /// Card row centered: columns as space allows, up to four.
    private func recentSection(width: CGFloat) -> some View {
        let shown = showsAll ? items : Array(items.prefix(Self.collapsedCount))
        let fitting = Int((width + Self.cardSpacing) / (Self.cardWidth + Self.cardSpacing))
        let columns = max(1, min(Self.collapsedCount, fitting, shown.count))
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("Recent")).overlineStyle()
                Spacer()
                if items.count > Self.collapsedCount {
                    Button(showsAll ? L10n.text("Collapse") : L10n.text("Show all  →")) {
                        withAnimation(.spring(duration: 0.35)) { showsAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(KinroxFont.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(Self.cardWidth), spacing: Self.cardSpacing),
                    count: columns),
                alignment: .leading, spacing: Self.cardSpacing
            ) {
                ForEach(shown) { item in
                    RecentCard(
                        item: item,
                        isAvailable: !(recents?.unavailable.contains(item.id) ?? false),
                        open: { actions.openRecent(item) },
                        revealInFinder: {
                            if let url = recents?.resolve(item) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } else {
                                recents?.refreshAvailability()
                            }
                        },
                        remove: { recents?.remove(item.id) })
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
