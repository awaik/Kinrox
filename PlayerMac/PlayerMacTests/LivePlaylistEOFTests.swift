import Foundation
import Testing

@testable import Kinrox

@Suite("Live playlist EOF", .timeLimit(.minutes(1)))
@MainActor
struct LivePlaylistEOFTests {
    private let first = URL(fileURLWithPath: "/virtual/Series/1.mkv")
    private let second = URL(fileURLWithPath: "/virtual/Series/2.mkv")

    private func open(_ model: PlayerViewModel) async throws {
        model.open(url: first)
        model.receive(.started)
        model.receive(.loaded)
        try await waitForFolder { model.playlist != nil }
    }

    @Test("A clean reachable neighbor advances synchronously")
    func synchronousAdvance() async throws {
        let driver = FolderTestDriver()
        driver.setItems([first, second])
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, folderDependencies: driver.dependencies)
        try await open(model)
        model.receive(.property(.endReached, .flag(true)))
        #expect(engine.openedURLs == [first, second])
        #expect(driver.scans == 1)
        await model.shutdown()
    }

    @Test("EOF discovers a missed publication once without a watcher event")
    func missedEvent() async throws {
        let driver = FolderTestDriver()
        driver.setItems([first])
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, folderDependencies: driver.dependencies)
        try await open(model)
        driver.setItems([first, second])
        model.receive(.property(.endReached, .flag(true)))
        try await waitForFolder { model.currentURL == second }
        model.receive(.property(.endReached, .flag(true)))
        #expect(engine.openedURLs == [first, second])
        #expect(driver.scans == 2 && driver.maxActive == 1)
        await model.shutdown()
    }

    @Test("Dirty and missing neighbors force immediate validation", arguments: [true, false])
    func staleNeighbor(dirty: Bool) async throws {
        let driver = FolderTestDriver()
        driver.setItems([first, second])
        let engine = FakePlayerEngine()
        var dependencies = driver.dependencies
        if !dirty { dependencies.isReachable = { _ in false } }
        let model = PlayerViewModel(engine: engine, folderDependencies: dependencies)
        try await open(model)
        driver.setItems([first])
        if dirty {
            driver.send()
            while await driver.clock.pending.isEmpty { await Task.yield() }
        }
        model.receive(.property(.endReached, .flag(true)))
        try await waitForFolder { model.eofTask == nil && driver.scans == 2 }
        #expect(engine.openedURLs == [first])
        #expect(model.isAtEnd && !model.canNext)
        await model.shutdown()
    }

    @Test("User intent cancels pending EOF advancement", arguments: 0..<7)
    func cancelEOF(action: Int) async throws {
        let driver = FolderTestDriver()
        driver.setItems([first])
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, folderDependencies: driver.dependencies)
        try await open(model)
        driver.setItems([first, second])
        driver.holdScans(true)
        defer { driver.holdScans(false) }
        model.receive(.property(.endReached, .flag(true)))
        try await waitForFolder { driver.active == 1 }
        switch action {
        case 0: model.setPaused(false)
        case 1: model.setPaused(true)
        case 2: model.seek(to: 10)
        case 3: model.seek(by: -10)
        case 4: model.open(url: first)
        case 5: model.receive(.started)
        default: await model.shutdown()
        }
        let commands = engine.commands
        driver.holdScans(false)
        if action == 6 {
            try await waitForFolder { driver.active == 0 }
            #expect(model.playlist == nil)
        } else {
            try await waitForFolder { model.canNext }
        }
        #expect(model.eofTask == nil)
        #expect(engine.commands == commands)
        await model.shutdown()
    }

    @Test("An empty or failed EOF check cannot start a later download", arguments: [true, false])
    func laterPublication(fails: Bool) async throws {
        let driver = FolderTestDriver()
        driver.setItems([first])
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, folderDependencies: driver.dependencies)
        try await open(model)
        driver.setItems([], fails: fails)
        model.receive(.property(.endReached, .flag(true)))
        try await waitForFolder { model.eofTask == nil && driver.scans == 2 }
        driver.setItems([first, second])
        driver.send()
        try await driver.clock.advance()
        try await waitForFolder { model.canNext }
        #expect(model.isAtEnd && model.currentURL == first)
        #expect(engine.openedURLs == [first])
        await model.shutdown()
    }

    @Test("EOF waits for a fresh serial scan when enumeration is already in flight")
    func eofJoinsWorker() async throws {
        let driver = FolderTestDriver()
        driver.setItems([first])
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, folderDependencies: driver.dependencies)
        try await open(model)
        driver.holdScans(true)
        defer { driver.holdScans(false) }
        driver.send()
        try await driver.clock.advance()
        try await waitForFolder { driver.active == 1 }
        model.receive(.property(.endReached, .flag(true)))
        driver.setItems([first, second])
        driver.holdScans(false)
        try await waitForFolder { model.currentURL == second }
        #expect(driver.scans == 3 && driver.maxActive == 1)
        #expect(engine.openedURLs == [first, second])
        await model.shutdown()
    }
}
