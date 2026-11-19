import SwiftUI

struct HomeWorkspaceView: View {
    @Bindable var session: PlayerSession
    let model: PlayerViewModel
    let actions: PlayerActions
    var remote: RemoteServer?
    var updates: UpdateCenter?

    static let sidebarWidth: CGFloat = 248
    static func showsSidebar(width: CGFloat) -> Bool { width >= 920 }

    var body: some View {
        GeometryReader { geometry in
            let sidebar = Self.showsSidebar(width: geometry.size.width)
            let width = max(1, geometry.size.width - (sidebar ? Self.sidebarWidth : 0))
            HStack(spacing: 0) {
                if sidebar {
                    HomeSidebarView(session: session, actions: actions)
                        .frame(width: Self.sidebarWidth)
                }
                VStack(spacing: 0) {
                    if !sidebar { compactNavigation }
                    if geometry.size.width < 720, session.isHomeSearchShown {
                        HomeSearchField(session: session, inline: true).padding(
                            [.horizontal, .bottom], 12)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let updates, updates.showsReminder, let update = updates.available {
                                UpdateBanner(center: updates, update: update)
                            }
                            if model.hasMedia, model.isShowingHome, session.homeSection == .overview
                            {
                                ContinueWatchingBanner(
                                    model: model, availableWidth: max(1, width - 48))
                            }
                            workspace
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                        .frame(width: width)
                    }
                    .accessibilityIdentifier("home-workspace-scroll")
                    if session.localAudio.currentTrack != nil {
                        LocalAudioMiniPlayerBar(player: session.localAudio)
                    }
                }
                .frame(width: width)
            }
        }
        .foregroundStyle(Palette.textPrimary)
        .background(Palette.base)
        .onAppear { session.recents.refreshAvailability() }
        .sheet(isPresented: $session.isLibrarySheetShown) {
            LibraryFoldersSheet(store: session.mediaLibrary, actions: actions)
        }
        .alert(
            L10n.text("Local Audio"),
            isPresented: Binding(
                get: { session.localAudio.errorMessage != nil },
                set: { if !$0 { session.localAudio.errorMessage = nil } })
        ) {
            Button(L10n.text("Dismiss")) { session.localAudio.errorMessage = nil }
        } message: {
            Text(session.localAudio.errorMessage ?? "")
        }
    }

    @ViewBuilder private var workspace: some View {
        let library = session.mediaLibrary
        switch session.homeSection {
        case .overview:
            if library.folders.isEmpty && session.homeFilter.query.isEmpty {
                HomeOverviewView(session: session, model: model, showsCatalog: false)
                HomeEmptyStateView(
                    actions: actions,
                    connect: remote == nil ? nil : { model.isShowingConnectPhone = true })
                if library.enrichMetadata {
                    Text(
                        L10n.text(
                            "Media titles and album artists are sent to Cinemeta, TVMaze, MusicBrainz, and Cover Art Archive."
                        )
                    )
                    .font(KinroxFont.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                }
            } else {
                HomeOverviewView(session: session, model: model)
            }
        case .video:
            HomeVideoLibraryView(session: session, model: model)
        case .audio:
            HomeLocalMusicView(session: session)
        case .recent:
            HomeRecentView(session: session, model: model, actions: actions)
        }
    }

    private var compactNavigation: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(HomeSection.allCases, id: \.self) { section in
                    Button {
                        session.homeSection = section
                    } label: {
                        Label(section.title, systemImage: section.icon)
                    }
                }
            } label: {
                Label(session.homeSection.title, systemImage: session.homeSection.icon).lineLimit(1)
            }
            .fixedSize()
            Spacer(minLength: 0)
            Button(L10n.text("Open File…"), action: actions.openFile)
            Button {
                session.isLibrarySheetShown = true
            } label: {
                Label(L10n.text("Folders"), systemImage: "folder")
            }
        }
        .font(KinroxFont.caption)
        .padding(12)
        .background(Palette.canvas)
    }
}

extension HomeSection {
    var title: String {
        switch self {
        case .overview: L10n.text("Overview")
        case .video: L10n.text("Movies & Series")
        case .audio: L10n.text("Music on This Mac")
        case .recent: L10n.text("Recent")
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .video: "film"
        case .audio: "music.note.house"
        case .recent: "clock.arrow.circlepath"
        }
    }
}

struct HomeEmptyStateView: View {
    let actions: PlayerActions
    var connect: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image("KinroxLogo")
                .resizable().scaledToFit().frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            Text(L10n.text("Movies and local music in one place"))
                .font(KinroxFont.titleLarge(24))
                .multilineTextAlignment(.center)
            Text(
                L10n.text(
                    "Add folders for automatic scanning, or drop a video or audio file here to play it."
                )
            )
            .font(KinroxFont.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: 440)
            HomePill(
                title: L10n.text("Add Folder…"), icon: "folder.badge.plus", prominent: true,
                action: actions.chooseFolders)
            HomePill(title: L10n.text("Open File…"), icon: "folder", action: actions.openFile)
            if let connect {
                RemotePillButton(title: L10n.text("Connect iPhone"), icon: "wifi", action: connect)
            }
            Text(
                L10n.text(
                    "Home plays files from this Mac and connected drives. Streaming is under Spotify."
                )
            )
            .font(KinroxFont.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: 400)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("home-empty-state")
    }
}
