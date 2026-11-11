import Foundation
import RemoteProtocol
import Testing

@testable import RemoteiOS

@MainActor final class FakeLockScreenPresenter: LockScreenPresenter {
    var initialContent: LockScreenAttributes.ContentState?
    var retained: LockScreenAttributes.ContentState?
    var isShowing = false
    var shown: [(content: LockScreenAttributes.ContentState, stale: Date?)] = []
    var ended: [(content: LockScreenAttributes.ContentState?, dismissAt: Date?)] = []
    func show(_ content: LockScreenAttributes.ContentState, staleDate: Date?) {
        isShowing = true
        retained = content
        shown.append((content, staleDate))
    }
    func end(_ content: LockScreenAttributes.ContentState?, dismissAt: Date?) {
        guard isShowing || retained != nil else { return }
        if dismissAt == nil { retained = nil }
        isShowing = false
        ended.append((content, dismissAt))
    }
    var last: LockScreenAttributes.ContentState? { shown.last?.content }
}

@MainActor
struct LockScreenControllerTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func content(paused: Bool = false, position: Double = 30, at offset: Double = 0)
        -> LockScreenAttributes.ContentState
    {
        .init(
            media: .music, title: "Song", subtitle: "Artist", macName: "Mac", paused: paused,
            position: position, duration: 200, anchor: start.addingTimeInterval(offset),
            canPrevious: true, canNext: true, canVolume: true, nextTitle: "Next",
            nextSubtitle: "Other")
    }

    @Test func showsOnceAndUpdatesOnlyOnVisibleChangeOrJump() {
        let presenter = FakeLockScreenPresenter()
        let controller = LockScreenActivityController(presenter: presenter) { self.start }
        controller.sync(content())
        #expect(presenter.shown.count == 1)
        #expect(presenter.shown[0].stale == start.addingTimeInterval(173))
        controller.sync(content(position: 40, at: 10))  // Extrapolated position matches.
        #expect(presenter.shown.count == 1)
        controller.sync(content(position: 90, at: 10))  // Seek on the Mac.
        #expect(presenter.shown.count == 2)
        controller.sync(content(paused: true, position: 90, at: 10))
        #expect(presenter.shown.count == 3)
        #expect(presenter.shown[2].stale == nil)
        controller.sync(nil)
        #expect(!presenter.isShowing && presenter.ended.count == 1)
    }

    @Test func pausedCardEndsAfterAnHour() {
        let presenter = FakeLockScreenPresenter()
        var now = start
        let controller = LockScreenActivityController(presenter: presenter) { now }
        controller.sync(content(paused: true))
        controller.didEnterBackground()
        #expect(presenter.ended.last?.dismissAt == start.addingTimeInterval(3600))
        #expect(presenter.ended.last?.content?.paused == true)

        now = start.addingTimeInterval(1800)
        controller.sync(content(paused: true, at: 1800))
        #expect(presenter.isShowing)  // Reopened while still within the hour.
        now = start.addingTimeInterval(3600)
        controller.sync(content(paused: true, at: 3600))
        #expect(!presenter.isShowing)
        controller.sync(content(paused: false, at: 3700))
        #expect(presenter.isShowing)
    }

    @Test func sendingAndUnreachableKeepTheLastTrack() {
        let presenter = FakeLockScreenPresenter()
        let controller = LockScreenActivityController(presenter: presenter) { self.start }
        controller.markSending(.next)
        #expect(presenter.shown.isEmpty)
        controller.sync(content())
        controller.markSending(.next)
        #expect(presenter.last?.phase == .sending && presenter.last?.sending == .next)
        controller.markUnreachable()
        #expect(presenter.last?.phase == .unreachable && presenter.last?.title == "Song")
        #expect(presenter.shown.last?.stale == nil)
        controller.sync(content())
        #expect(presenter.last?.phase == .live && presenter.last?.sending == nil)
    }
    @Test func endedPausedCardCanBeRemovedAndRecreatedForFeedback() {
        let presenter = FakeLockScreenPresenter()
        let controller = LockScreenActivityController(presenter: presenter) { self.start }
        controller.sync(content(paused: true))
        controller.didEnterBackground()
        #expect(!presenter.isShowing && presenter.retained != nil)
        controller.markSending(.togglePause)
        #expect(presenter.isShowing && presenter.last?.phase == .sending)
        controller.didEnterBackground()
        controller.markUnreachable()
        #expect(presenter.isShowing && presenter.last?.phase == .unreachable)
        controller.didEnterBackground()
        controller.sync(nil)
        #expect(presenter.retained == nil && presenter.ended.last?.dismissAt == nil)
    }

    @Test(arguments: [false, true])
    func coldLaunchRecoversContentForSendingAndUnavailable(paused: Bool) {
        let presenter = FakeLockScreenPresenter()
        presenter.initialContent = content(paused: paused)
        presenter.retained = presenter.initialContent
        presenter.isShowing = !paused
        let controller = LockScreenActivityController(presenter: presenter) { self.start }
        #expect(controller.content?.title == "Song")
        #expect(controller.pausedSince == (paused ? start : nil))
        controller.markSending(.next)
        #expect(presenter.last?.phase == .sending)
        controller.markUnreachable()
        #expect(presenter.last?.phase == .unreachable)
    }

    @Test func coldLaunchKeepsOriginalPauseDeadlineAndSharedPresentation() throws {
        let first = FakeLockScreenPresenter()
        let original = LockScreenActivityController(presenter: first) { self.start }
        original.sync(content(paused: true))
        original.sync(content(paused: true, at: 1800))
        let restored = FakeLockScreenPresenter()
        restored.initialContent = first.last
        let controller = LockScreenActivityController(presenter: restored) {
            self.start.addingTimeInterval(3600)
        }
        #expect(controller.pausedSince == start)
        controller.sync(content(paused: true, at: 3600))
        #expect(!restored.isShowing)

        var state = content()
        var text = LockScreenPresentation(state: state, isStale: true)
        #expect(text.title == "Next" && text.subtitle == "Other" && text.showsNext)
        state.phase = .unreachable
        text = LockScreenPresentation(state: state, isStale: true)
        #expect(text.title == L10n.text("Mac unavailable"))
        #expect(text.subtitle == L10n.text("Open Kinrox Remote") && !text.showsNext)
        state.phase = .sending
        text = LockScreenPresentation(state: state, isStale: true)
        #expect(text.title == "Song" && !text.showsNext)
    }

}

@MainActor
struct LockScreenRemoteTests {
    private func harness() -> (RemoteModelHarness, FakeLockScreenPresenter) {
        let presenter = FakeLockScreenPresenter()
        let h = RemoteModelHarness(
            lockScreen: LockScreenActivityController(presenter: presenter))
        return (h, presenter)
    }

    @Test func confirmedStateDrivesTheCard() throws {
        let (h, presenter) = harness()
        defer { h.model.stop() }
        h.connect()
        let video = try #require(presenter.last)
        #expect(video.media == .video && video.title == "Video.mkv")
        #expect(video.subtitle == L10n.text("Video") && video.macName == "Mac")
        #expect(video.canPrevious && video.canNext)
        #expect(h.model.lockScreenCommand(.back10) == .seekRelative(seconds: -10))
        #expect(h.model.lockScreenCommand(.volumeUp) == .setVolume(volume: 5))
        #expect(h.model.lockScreenCommand(.volumeDown) == .setVolume(volume: 0))

        var music = RemoteModelHarness.playing
        music.source = .music
        music.music = .init(
            track: .init(
                id: "a", title: "Song", artists: ["One", "Two"], album: "", year: "",
                duration: 100),
            nextTrack: .init(
                id: "b", title: "Next", artists: ["Three"], album: "", year: "", duration: 90),
            liked: false, shuffle: false, repeatMode: .off, queueCount: 2,
            queueRevision: UUID(), libraryRevision: UUID(), outputName: "Out",
            volumeKnown: false)
        music.canNext = false
        h.current.emit(music)
        let card = try #require(presenter.last)
        #expect(card.media == .music && card.subtitle == "One, Two" && card.nextTitle == "Next")
        #expect(!card.canNext && card.canPrevious && !card.canVolume)
        #expect(h.model.lockScreenCommand(.volumeUp) == nil)

        var stopped = music
        stopped.hasMedia = false
        h.current.emit(stopped)
        #expect(!presenter.isShowing)
    }

    @Test func settingTurnsTheCardOffAndIsRemembered() {
        let (h, presenter) = harness()
        defer { h.model.stop() }
        h.connect()
        #expect(presenter.isShowing && h.preferences.lockScreenControls)
        h.model.lockScreenControls = false
        #expect(!presenter.isShowing && !h.preferences.lockScreenControls)
        h.current.emit(RemoteModelHarness.playing)
        #expect(!presenter.isShowing)
        h.model.lockScreenControls = true
        #expect(presenter.isShowing)
        h.model.returnToPlayers()
        #expect(!presenter.isShowing)
    }

    @Test func backgroundPressReconnectsSendsAndDisconnects() async throws {
        let (h, presenter) = harness()
        defer { h.model.stop() }
        h.connect()
        h.model.enterBackground()
        #expect(h.model.connectionState == .idle && h.connections.count == 1)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]

        let press = Task { await h.model.performLockScreen(.togglePause) }
        try await waitForRemote { h.connections.count == 2 }
        #expect(presenter.last?.phase == .sending && presenter.last?.sending == .togglePause)
        #expect(h.model.screen == .remote)
        h.current.connected()
        h.current.emit(RemoteModelHarness.playing)
        try await waitForRemote { !h.current.commands.isEmpty }
        let sent = try #require(h.current.messages.last)
        #expect(h.current.commands == [.togglePause])
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: sent.header.id))))
        var paused = RemoteModelHarness.playing
        paused.paused = true
        h.current.emit(paused)
        await press.value
        #expect(presenter.last?.phase == .live && presenter.last?.paused == true)
        #expect(h.model.connectionState == .connected)

        h.clock.advance(RemoteAppModel.lockScreenIdleDelay)
        #expect(h.model.connectionState == .idle && !h.model.lockScreenSession)
        // Paused in the background: the card dismisses itself an hour later.
        #expect(presenter.ended.last?.dismissAt != nil)
    }

    @Test func pressWithoutAccessMarksMacUnavailable() async {
        let (h, presenter) = harness()
        defer { h.model.stop() }
        h.connect()
        h.model.enterBackground()
        h.store.records.removeAll()
        await h.model.performLockScreen(.next)
        #expect(presenter.last?.phase == .unreachable)
        #expect(h.current.commands.isEmpty)
    }

    @Test func openingTheRemoteTakesOverTheSession() async throws {
        let (h, _) = harness()
        defer { h.model.stop() }
        h.connect()
        h.model.enterBackground()
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.model.beginLockScreenSession()
        try await waitForRemote { h.connections.count == 2 }
        h.current.connected()
        h.current.emit(RemoteModelHarness.playing)
        h.model.scheduleLockScreenSessionEnd()
        h.model.enterForeground()
        h.clock.advance(RemoteAppModel.lockScreenIdleDelay)
        #expect(h.model.controlsEnabled && !h.model.lockScreenSession)
    }
    @Test func rapidVolumePressesAccumulateAndKeepSendingUntilLastReply() async throws {
        let (h, presenter) = harness()
        defer { h.model.stop() }
        h.connect()
        let first = Task { await h.model.performLockScreen(.volumeUp) }
        try await waitForRemote { h.current.commands.count == 1 }
        let second = Task { await h.model.performLockScreen(.volumeUp) }
        try await waitForRemote { h.current.commands.count == 2 }
        let third = Task { await h.model.performLockScreen(.volumeUp) }
        try await waitForRemote { h.current.commands.count == 3 }
        #expect(
            h.current.commands == [
                .setVolume(volume: 5), .setVolume(volume: 10), .setVolume(volume: 15),
            ])
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: h.current.messages[0].header.id))))
        var confirmed = RemoteModelHarness.playing
        confirmed.volume = 5
        h.current.emit(confirmed)
        await first.value
        #expect(presenter.last?.phase == .sending)
        for message in h.current.messages.dropFirst() {
            h.current.onEvent?(.message(.ack(.init(), .init(replyTo: message.header.id))))
        }
        confirmed.volume = 15
        h.current.emit(confirmed)
        await second.value
        await third.value
        #expect(presenter.last?.phase == .live)
    }

    @Test func coldBackgroundSessionStaysBoundedWithoutForegroundScene() async throws {
        let h = RemoteModelHarness(restore: true, autostart: false)
        defer { h.model.stop() }
        #expect(!h.model.started && !h.model.foreground && !h.model.sceneActive)
        h.model.beginLockScreenSession()
        #expect(h.model.started && h.model.lockScreenSession && !h.model.sceneActive)
        try await waitForRemote { h.connections.count == 1 }
        h.current.connected()
        h.current.emit(RemoteModelHarness.playing)
        h.model.scheduleLockScreenSessionEnd()
        h.clock.advance(RemoteAppModel.lockScreenIdleDelay)
        #expect(!h.model.foreground && !h.model.lockScreenSession)
        #expect(h.model.connectionState == .idle)
    }

}
