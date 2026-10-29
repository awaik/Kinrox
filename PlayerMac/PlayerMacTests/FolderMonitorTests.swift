import AppKit
import Testing

@testable import Kinrox

@Suite("Live folder monitor", .timeLimit(.minutes(1)))
@MainActor
struct FolderMonitorTests {
    private let folder = URL(fileURLWithPath: "/virtual/Series", isDirectory: true)
    private var episodes: [URL] {
        (1...3).map { folder.appendingPathComponent("Episode \($0).mkv") }
    }

    @Test("A custom snapshot provider can opt into a live watcher")
    func providerWithWatcher() async throws {
        let driver = FolderTestDriver()
        let folder = folder
        let scan = driver.dependencies.scan
        driver.setItems([episodes[0]])
        let model = PlayerViewModel(
            engine: FakePlayerEngine(), folderDependencies: driver.dependencies
        ) { url in
            FolderPlaylist(items: (try? scan(folder)) ?? [], current: url)
        }
        model.open(url: episodes[0])
        try await waitForFolder { model.playlist != nil }
        driver.setItems(episodes)
        driver.send()
        try await driver.clock.advance()
        try await waitForFolder { model.canNext }
        #expect(driver.watches.count == 1)
        await model.shutdown()
    }

    @Test("An initially unavailable watcher recovers on the fallback interval")
    func initiallyUnavailable() async throws {
        let driver = FolderTestDriver()
        driver.setWatchUnavailable(true)
        driver.setItems([], fails: true)
        let model = PlayerViewModel(
            engine: FakePlayerEngine(), folderDependencies: driver.dependencies)
        model.open(url: episodes[0])
        try await waitForFolder { model.playlist != nil }
        driver.setWatchUnavailable(false)
        driver.setItems(episodes)
        try await driver.clock.advance(.seconds(10))
        try await waitForFolder { model.canNext }
        #expect(driver.watches.count == 2)
        await model.shutdown()
    }

    @Test("One-shot refresh returns its own snapshot even after a newer publication")
    func refreshSnapshot() async throws {
        let driver = FolderTestDriver()
        let initial = [episodes[0]]
        driver.setItems(initial)
        var published: [URL]?
        let monitor = FolderMonitor(folder: folder, dependencies: driver.dependencies) {
            published = try? $0.get()
        }
        defer { monitor.stop() }
        try await waitForFolder { published == initial }
        let firstRefresh = Task { await monitor.refresh() }
        _ = await firstRefresh.value
        driver.setItems(episodes)
        _ = await monitor.refresh()
        #expect(published == episodes)
        #expect(await firstRefresh.value == initial)
    }

    @Test("Bursts share a fixed window; changes during enumeration get one follow-up")
    func burstAndInFlightChanges() async throws {
        let driver = FolderTestDriver()
        driver.setItems([episodes[0]])
        let model = PlayerViewModel(
            engine: FakePlayerEngine(), folderDependencies: driver.dependencies)
        defer { driver.holdScans(false) }
        model.open(url: episodes[0])
        try await waitForFolder { model.playlist != nil }
        driver.setItems(Array(episodes.prefix(2)))
        driver.holdScans(true)
        for _ in 0..<100 { driver.send() }
        try await driver.clock.advance()
        try await waitForFolder { driver.active == 1 }
        driver.setItems(episodes)
        for _ in 0..<100 { driver.send() }
        driver.holdScans(false)
        try await waitForFolder { model.playlist?.count == 2 }
        try await driver.clock.advance()
        try await waitForFolder { model.playlist?.count == 3 }
        #expect(driver.scans == 3 && driver.maxActive == 1)
        await model.shutdown()
        try await waitForFolder { driver.terminations == 1 }
    }

    @Test("A same-folder switch reconciles an in-flight scan with the latest current item")
    func sameFolderScan() async throws {
        let driver = FolderTestDriver()
        driver.setItems(episodes)
        driver.holdScans(true)
        defer { driver.holdScans(false) }
        let model = PlayerViewModel(
            engine: FakePlayerEngine(), folderDependencies: driver.dependencies)
        model.open(url: episodes[0])
        try await waitForFolder { driver.active == 1 }
        model.open(url: episodes[1])
        driver.holdScans(false)
        try await waitForFolder { model.playlist?.index == 1 }
        #expect(driver.watches == [folder])
        #expect(driver.scans == 1)
        await model.shutdown()
    }

    @Test("Old folder and shutdown completions cannot publish", arguments: [true, false])
    func obsoleteScan(switchFolder: Bool) async throws {
        let driver = FolderTestDriver()
        driver.setItems(episodes)
        driver.holdScans(true)
        defer { driver.holdScans(false) }
        let model = PlayerViewModel(
            engine: FakePlayerEngine(), folderDependencies: driver.dependencies)
        model.open(url: episodes[0])
        try await waitForFolder { driver.active == 1 }
        let other = URL(fileURLWithPath: "/virtual/Other/Film.mkv")
        if switchFolder {
            driver.setItems([other])
            model.open(url: other)
            try await waitForFolder { driver.active == 2 }
        } else {
            await model.shutdown()
        }
        driver.holdScans(false)
        try await waitForFolder { driver.active == 0 }
        if switchFolder {
            try await waitForFolder { model.playlist?.current == other }
            #expect(model.playlist?.items == [other])
        } else {
            #expect(model.playlist == nil && model.currentURL == nil)
        }
        await model.shutdown()
        try await waitForFolder { driver.terminations == driver.watches.count }
    }

    @Test("Read errors retain an anchor initially and preserve the last valid snapshot")
    func readFailure() async throws {
        let driver = FolderTestDriver()
        driver.setItems([], fails: true)
        let model = PlayerViewModel(
            engine: FakePlayerEngine(), folderDependencies: driver.dependencies)
        model.open(url: episodes[0])
        try await waitForFolder { model.playlist != nil }
        #expect(model.playlist?.items == [episodes[0]])
        driver.setItems(episodes)
        driver.send()
        try await driver.clock.advance()
        try await waitForFolder { model.playlist?.count == 3 }
        let snapshot = model.playlist
        var notifications = 0
        let observation = model.observePlayback { _ in notifications += 1 }
        driver.setItems([], fails: true)
        driver.send()
        try await driver.clock.advance()
        try await waitForFolder { driver.scans == 3 && driver.active == 0 }
        // A successful unchanged refresh provides a barrier after the failed scan.
        driver.setItems(episodes)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        try await waitForFolder { driver.scans == 4 && driver.active == 0 }
        #expect(model.playlist == snapshot && model.errorMessage == nil)
        #expect(notifications == 0)
        model.removePlaybackObserver(observation)
        await model.shutdown()
    }

    @Test("Wake rescans without a playback event")
    func wake() async throws {
        let driver = FolderTestDriver()
        driver.setItems([episodes[0]])
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, folderDependencies: driver.dependencies)
        model.open(url: episodes[0])
        try await waitForFolder { model.playlist != nil }
        driver.setItems(episodes)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        try await waitForFolder { model.canNext }
        #expect(engine.commands == [.load(episodes[0])])
        await model.shutdown()
    }

    @Test("Invalidation reattaches, unavailable watchers poll until watching resumes")
    func recovery() async throws {
        let driver = FolderTestDriver()
        driver.setItems([episodes[0]])
        let model = PlayerViewModel(
            engine: FakePlayerEngine(), folderDependencies: driver.dependencies)
        model.open(url: episodes[0])
        try await waitForFolder { model.playlist != nil }
        driver.setWatchUnavailable(true)
        driver.send(.invalidated)
        driver.setItems(Array(episodes.prefix(2)))
        try await driver.clock.advance()
        try await waitForFolder { model.playlist?.count == 2 && driver.watches.count == 2 }
        driver.setWatchUnavailable(false)
        driver.setItems(episodes)
        try await driver.clock.advance(.seconds(10))
        try await waitForFolder { model.playlist?.count == 3 && driver.watches.count == 3 }
        #expect(await driver.clock.pending.isEmpty)
        #expect(driver.scans == 3)
        await model.shutdown()
    }
}
