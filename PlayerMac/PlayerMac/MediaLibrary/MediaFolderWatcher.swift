import AppKit
import CoreServices
import Foundation

@MainActor
final class MediaFolderWatcher {
    struct Dependencies {
        var notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        var makeStream:
            ([String], @escaping @Sendable () -> Void) -> (any MediaFolderWatchStream)? = {
                FoldersEventStream(paths: $0, changed: $1)
            }
    }

    private let dependencies: Dependencies
    private let changed: @MainActor () -> Void
    private let observers: WorkspaceVolumeObservers
    private var stream: (any MediaFolderWatchStream)?
    private var coalescing: Task<Void, Never>?
    private var paths: [String] = []

    init(dependencies: Dependencies = Dependencies(), changed: @escaping @MainActor () -> Void) {
        self.dependencies = dependencies
        self.changed = changed
        observers = WorkspaceVolumeObservers(center: dependencies.notificationCenter)
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.willUnmountNotification,
            NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification,
        ] {
            observers.tokens.append(
                dependencies.notificationCenter.addObserver(
                    forName: name, object: nil, queue: nil
                ) { [weak self] _ in
                    Task { @MainActor in self?.schedule() }
                })
        }
    }

    func watch(_ folders: [WatchedFolder]) {
        let desired = folders.filter { !$0.isOffline }.map(\.path).sorted()
        guard desired != paths else { return }
        paths = desired
        stream = nil
        if !desired.isEmpty {
            stream = dependencies.makeStream(desired) { [weak self] in
                Task { @MainActor in self?.schedule() }
            }
        }
    }

    private func schedule() {
        guard coalescing == nil else { return }
        coalescing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.coalescing = nil
            self.changed()
        }
    }
}

protocol MediaFolderWatchStream: AnyObject {}

private final class WorkspaceVolumeObservers {
    let center: NotificationCenter
    var tokens: [any NSObjectProtocol] = []
    init(center: NotificationCenter) { self.center = center }
    deinit { tokens.forEach(center.removeObserver) }
}

private final class FoldersEventStream: MediaFolderWatchStream {
    private final class Callback {
        let changed: @Sendable () -> Void
        init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
    }

    private let queue = DispatchQueue(label: "app.kinrox.media-library.fsevents", qos: .utility)
    private let stream: FSEventStreamRef

    init?(paths: [String], changed: @escaping @Sendable () -> Void) {
        let callback = Callback(changed)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        guard
            let stream = FSEventStreamCreate(
                nil,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().changed()
                }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.25, FSEventStreamCreateFlags(flags))
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        let stream = stream
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
