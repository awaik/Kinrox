import Foundation
import Testing

@testable import Kinrox

@Suite("Player commands and folder playlist", .timeLimit(.minutes(1)))
@MainActor
struct PlayerCommandsTests {
    private let folder = URL(fileURLWithPath: "/tmp/Series")
    private var episodes: [URL] { (1...3).map { folder.appendingPathComponent("E\($0).mkv") } }

    private func makeModel(_ engine: FakePlayerEngine) -> PlayerViewModel {
        let items = episodes
        return PlayerViewModel(engine: engine) { url in FolderPlaylist(items: items, current: url) }
    }

    /// Opens file and awaits background folder read.
    private func open(_ url: URL, in model: PlayerViewModel) async {
        model.open(url: url)
        model.receive(.started)
        model.receive(.loaded)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.playlist?.current != url, ContinuousClock.now < deadline { await Task.yield() }
    }

    @Test("Without file commands send nothing to engine")
    func commandsNeedMedia() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        model.togglePause()
        model.seek(by: 5)
        model.seek(to: 10)
        model.next()
        #expect(engine.commands.isEmpty)
        await model.shutdown()
    }

    @Test("Pause, relative and absolute seek bounded by duration")
    func playbackCommands() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        await open(episodes[0], in: model)
        model.receive(.property(.duration, .number(100)))
        engine.commands.removeAll()
        model.togglePause()
        model.receive(.property(.paused, .flag(true)))
        model.togglePause()
        model.seek(by: -PlayerViewModel.longSeek)
        model.seek(to: 250)
        model.seek(to: -3)
        #expect(
            engine.commands == [
                .paused(true), .paused(false), .seekRelative(-30), .seekAbsolute(100),
                .seekAbsolute(0),
            ])
        await model.shutdown()
    }

    @Test("Volume changes in steps of 5 within 0-100 and reflects immediately in model")
    func volumeSteps() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        model.receive(.property(.volume, .number(97)))
        model.changeVolume(by: PlayerViewModel.volumeStep)
        #expect(model.volume == 100)
        model.setVolume(-20)
        #expect(model.volume == 0)
        #expect(engine.commands == [.volume(100), .volume(0)])
        await model.shutdown()
    }

    @Test("Next and previous files taken from folder")
    func nextPrevious() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        await open(episodes[1], in: model)
        #expect(model.canNext && model.canPrevious)
        #expect(model.playlistCaption == "2 of 3 · Series")
        model.next()
        #expect(engine.openedURLs.last == episodes[2])
        #expect(model.playlist?.current == episodes[2])
        #expect(!model.canNext)
        model.previous()
        model.previous()
        #expect(engine.openedURLs.suffix(2) == [episodes[1], episodes[0]])
        await model.shutdown()
    }

    @Test("File end opens next; player holds on last file")
    func autoAdvance() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        await open(episodes[1], in: model)
        model.receive(.property(.endReached, .flag(true)))
        #expect(engine.openedURLs.last == episodes[2])
        await open(episodes[2], in: model)
        let count = engine.openedURLs.count
        model.receive(.property(.endReached, .flag(true)))
        #expect(engine.openedURLs.count == count)
        #expect(model.isAtEnd)
        await model.shutdown()
    }

    @Test("Auto-advance can be disabled")
    func autoAdvanceDisabled() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        model.autoAdvance = false
        await open(episodes[0], in: model)
        model.receive(.property(.endReached, .flag(true)))
        #expect(engine.openedURLs == [episodes[0]])
        await model.shutdown()
    }

    @Test("\"Play\" at file end begins it from start")
    func replayAtEnd() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        model.autoAdvance = false
        await open(episodes[2], in: model)
        model.receive(.property(.paused, .flag(true)))
        model.receive(.property(.endReached, .flag(true)))
        engine.commands.removeAll()
        model.togglePause()
        #expect(engine.commands == [.seekAbsolute(0), .paused(false)])
        await model.shutdown()
    }

    @Test("Full Screen toggles window via injected action")
    func fullscreenHook() async {
        let model = makeModel(FakePlayerEngine())
        var toggles = 0
        model.onToggleFullscreen = { toggles += 1 }
        model.toggleFullscreen()
        #expect(toggles == 1)
        await model.shutdown()
    }

    @Test("Explicit play at end and quick repeated space")
    func replayThenPause() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        await open(episodes[2], in: model)
        model.receive(.property(.paused, .flag(true)))
        model.receive(.property(.endReached, .flag(true)))
        engine.commands.removeAll()
        model.setPaused(false)
        model.togglePause()
        #expect(engine.commands == [.seekAbsolute(0), .paused(false), .paused(true)])
        // Until engine confirmation, displayed state remains unchanged.
        #expect(model.paused)
        await model.shutdown()
    }

    @Test("Two quick spaces at end do not send duplicate seek")
    func repeatedReplayToggle() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        await open(episodes[2], in: model)
        model.receive(.property(.paused, .flag(true)))
        model.receive(.property(.endReached, .flag(true)))
        engine.commands.removeAll()
        model.togglePause()
        model.togglePause()
        #expect(engine.commands == [.seekAbsolute(0), .paused(false), .paused(true)])
        await model.shutdown()
    }

}
