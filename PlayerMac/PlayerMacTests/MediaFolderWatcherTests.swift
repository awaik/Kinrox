import AppKit
import Foundation
import Testing

@testable import Kinrox

@MainActor
struct MediaFolderWatcherTests {
    @Test func filesystemAndWorkspaceBurstsCoalesceAndOfflineFoldersStopTheirStream() async throws {
        let center = NotificationCenter()
        var streamPaths: [[String]] = []
        var signal: (@Sendable () -> Void)?
        var notifications = 0
        let watcher = MediaFolderWatcher(
            dependencies: .init(
                notificationCenter: center,
                makeStream: { paths, callback in
                    streamPaths.append(paths)
                    signal = callback
                    return Stream()
                }
            )
        ) { notifications += 1 }
        var folder = WatchedFolder(
            id: UUID(), path: "/Volumes/Test/Movies", displayName: "Movies", volumeUUID: "disk",
            isRemovable: true)
        watcher.watch([folder])
        #expect(streamPaths == [[folder.path]])
        signal?()
        signal?()
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(notifications == 1)
        folder.isOffline = true
        watcher.watch([folder])
        #expect(streamPaths.count == 1)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(notifications == 2)
    }

    private final class Stream: MediaFolderWatchStream {}
}
