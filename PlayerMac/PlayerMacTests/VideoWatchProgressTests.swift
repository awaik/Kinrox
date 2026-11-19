import Foundation
import Testing

@testable import Kinrox

@MainActor
struct VideoWatchProgressTests {
    @Test(arguments: [false, true])
    func savesNewProgressAfterSeekingBackOrReplayingAtEOF(replay: Bool) async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        model.autoAdvance = false
        var writes: [WatchProgress] = []
        model.writeWatchProgress = { writes.append($0) }
        model.open(url: URL(fileURLWithPath: "/tmp/Movie.mkv"))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(100)))
        model.receive(.property(.position, .number(95)))
        #expect(writes.last?.completed == true)

        if replay {
            model.receive(.property(.endReached, .flag(true)))
            #expect(model.setPaused(false))
            model.receive(.property(.endReached, .flag(false)))
            model.receive(.property(.position, .number(0)))
            #expect(writes.last?.completed == true)
        } else {
            #expect(model.seek(to: 25))
        }
        #expect(writes.count == 1)
        model.receive(.property(.position, .number(25)))
        model.receive(.property(.paused, .flag(true)))
        #expect(writes.last?.completed == false)
        #expect(writes.last?.position == 25)
        await model.shutdown()
    }

    @Test func eofIsPersistedBeforeAnotherLoadAndResumeSuppressesInitialPosition() async {
        let first = URL(fileURLWithPath: "/tmp/Series/S01E01.mkv")
        let second = URL(fileURLWithPath: "/tmp/Series/S01E02.mkv")
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine) { url in
            FolderPlaylist(items: [first, second], current: url)
        }
        var writes: [WatchProgress] = []
        model.writeWatchProgress = {
            if $0.completed { #expect(engine.openedURLs == [first]) }
            writes.append($0)
        }
        model.open(url: first, startPosition: 70)
        model.receive(.started)
        model.receive(.loaded)
        #expect(engine.commands.contains(.seekAbsolute(70)))
        model.receive(.property(.duration, .number(100)))
        model.receive(.property(.position, .number(9)))
        model.receive(.property(.paused, .flag(true)))
        #expect(writes.isEmpty)
        model.receive(.property(.position, .number(70)))
        #expect(writes.last?.position == 70)
        model.receive(.property(.endReached, .flag(true)))
        #expect(writes.last?.completed == true)
        await model.eofTask?.value
        #expect(engine.openedURLs == [first, second])
        #expect(writes.last?.path == VideoFiles.key(first))
        await model.shutdown()
    }

    @Test func openingTrackPanelLeavesHomeBeforePresenting() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        let url = URL(fileURLWithPath: "/tmp/Show/S01E07.mkv")
        model.open(url: url)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.paused, .flag(true)))
        #expect(model.showHome())
        #expect(model.isShowingHome)
        #expect(model.resume(url, from: nil, showTracks: true))
        #expect(!model.isShowingHome)
        #expect(model.trackController.presentation == .quick)
        #expect(engine.openedURLs == [url])
        await model.shutdown()
    }
}
