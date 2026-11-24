import Foundation

@MainActor
final class MPVAudioEngine: LocalAudioEngine {
    let events: AsyncStream<LocalAudioEvent>
    private let output: AsyncStream<LocalAudioEvent>.Continuation
    private let lifetime: AudioLifetime
    private var delivery: Task<Void, Never>?
    private var active: (entry: Int64, token: UUID)?
    private var startedEntry: Int64?
    private var loadedEntry: Int64?
    private var closed = false

    init(initialVolume: Double) throws {
        MPVPlayer.ensureNumericLocale()
        guard initialVolume.isFinite, let handle = mpv_create() else {
            throw MPVError("Cannot create the local audio player.")
        }
        let stream = AsyncStream<LocalAudioEvent>.makeStream()
        events = stream.stream
        output = stream.continuation
        let native = AsyncStream<AudioEvent>.makeStream()
        do {
            let disabled = [
                "vid", "audio-display", "keep-open", "ytdl", "config", "osc", "sub-auto",
                "audio-file-auto",
                "input-default-bindings", "input-vo-keyboard", "input-media-keys", "load-scripts",
                "load-stats-overlay", "load-console", "load-auto-profiles", "load-select",
                "load-positioning", "load-commands", "load-context-menu", "access-references",
            ]
            for option in disabled {
                try MPVError.check(mpv_set_option_string(handle, option, "no"), "Option \(option)")
            }
            for (option, value) in [
                ("vo", "null"), ("volume-max", "100"),
                ("volume", String(max(0, min(100, initialVolume)))), ("pause", "yes"),
                ("demuxer-max-bytes", "8MiB"), ("demuxer-max-back-bytes", "2MiB"),
            ] {
                try MPVError.check(mpv_set_option_string(handle, option, value), "Option \(option)")
            }
            for (id, name, format) in [
                (UInt64(1), "pause", MPV_FORMAT_FLAG),
                (2, "time-pos", MPV_FORMAT_DOUBLE),
                (3, "duration", MPV_FORMAT_DOUBLE),
            ] {
                try MPVError.check(
                    mpv_observe_property(handle, id, name, format), "Observing \(name)")
            }
            try MPVError.check(mpv_initialize(handle), "Local audio initialization")
            let loop = MPVEventLoop(
                handle: handle,
                receive: { event in
                    if let copied = AudioEvent(event) { native.continuation.yield(copied) }
                    return event.event_id != MPV_EVENT_SHUTDOWN
                }, finish: { native.continuation.finish() })
            lifetime = AudioLifetime(handle: handle, loop: loop)
            loop.start()
            delivery = Task { [weak self] in
                for await event in native.stream {
                    guard let self else { return }
                    self.receive(event)
                }
                self?.output.finish()
            }
        } catch {
            stream.continuation.finish()
            native.continuation.finish()
            mpv_terminate_destroy(handle)
            throw error
        }
    }

    deinit { lifetime.beginShutdown() }

    func load(_ url: URL, id: UUID, position: Double) throws {
        guard !closed else { throw MPVError("Local audio is shutting down.") }
        guard LocalAudioFiles.isAudio(url),
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw LocalAudioFailure.invalidFile }
        // Hold gain and pause during replacement. A paused entry cannot naturally
        // finish before its playlist ID is read, even for very short files.
        try command(["set", "pause", "yes"], wait: true)
        try command(["loadfile", url.path, "replace", "-1", "start=\(position)"], wait: true)
        var entry: Int64 = 0
        try MPVError.check(
            mpv_get_property(lifetime.handle, "playlist/0/id", MPV_FORMAT_INT64, &entry),
            "Identifying the local audio item")
        active = (entry, id)
        loadedEntry = nil
    }

    func setPaused(_ paused: Bool) throws {
        try command(["set", "pause", paused ? "yes" : "no"], wait: true)
    }

    func seek(_ position: Double) throws {
        try command(["seek", String(position), "absolute+exact"])
    }

    func setVolume(_ volume: Double) throws {
        try command(["set", "volume", String(volume)], wait: true)
    }

    func shutdown() async {
        closed = true
        delivery?.cancel()
        delivery = nil
        output.finish()
        await lifetime.shutdown()
    }

    private func receive(_ event: AudioEvent) {
        switch event {
        case .start(let entry): startedEntry = entry
        case .loaded:
            guard let active, active.entry == startedEntry else { return }
            loadedEntry = active.entry
            output.yield(.loaded(active.token))
        case .end(let entry, let reason, let code):
            guard let active, active.entry == entry else { return }
            if reason == MPV_END_FILE_REASON_EOF, loadedEntry == entry {
                output.yield(.ended(active.token))
            } else if reason == MPV_END_FILE_REASON_ERROR {
                output.yield(
                    .failed(
                        active.token,
                        MPVError(code: code, operation: "Local audio").localizedDescription))
            }
            loadedEntry = nil
        case .pause(let paused):
            if loadedEntry != nil { output.yield(.paused(paused)) }
        case .position(let seconds):
            if loadedEntry != nil, seconds.isFinite { output.yield(.position(seconds)) }
        case .duration(let seconds):
            if startedEntry == active?.entry, seconds.isFinite { output.yield(.duration(seconds)) }
        }
    }

    private func command(_ arguments: [String], wait: Bool = false) throws {
        guard !closed else { throw MPVError("Local audio is shutting down.") }
        let strings = arguments.map { strdup($0) }
        defer {
            for string in strings { free(string) }
        }
        var pointers = strings.map { $0.map { UnsafePointer($0) } } + [nil]
        guard strings.allSatisfy({ $0 != nil }) else {
            throw MPVError("Cannot submit local audio command.")
        }
        let result =
            wait
            ? mpv_command(lifetime.handle, &pointers)
            : mpv_command_async(lifetime.handle, 0, &pointers)
        try MPVError.check(result, "Local audio command")
    }
}

private enum AudioEvent: Sendable {
    case start(Int64)
    case loaded
    case end(Int64, mpv_end_file_reason, Int32)
    case pause(Bool)
    case position(Double)
    case duration(Double)

    init?(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_start_file.self) else {
                return nil
            }
            self = .start(data.pointee.playlist_entry_id)
        case MPV_EVENT_FILE_LOADED: self = .loaded
        case MPV_EVENT_END_FILE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self) else {
                return nil
            }
            self = .end(data.pointee.playlist_entry_id, data.pointee.reason, data.pointee.error)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard
                let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                let data = property.data
            else { return nil }
            switch event.reply_userdata {
            case 1: self = .pause(data.assumingMemoryBound(to: Int32.self).pointee != 0)
            case 2: self = .position(data.assumingMemoryBound(to: Double.self).pointee)
            case 3: self = .duration(data.assumingMemoryBound(to: Double.self).pointee)
            default: return nil
            }
        default: return nil
        }
    }
}

private final class AudioLifetime: @unchecked Sendable {
    let handle: OpaquePointer
    private let loop: MPVEventLoop
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var closing = false

    init(handle: OpaquePointer, loop: MPVEventLoop) {
        self.handle = handle
        self.loop = loop
        finished.enter()
    }

    func beginShutdown() {
        let shouldClose = lock.withLock {
            guard !closing else { return false }
            closing = true
            return true
        }
        guard shouldClose else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            loop.stopAndWait()
            mpv_terminate_destroy(handle)
            finished.leave()
        }
    }

    func shutdown() async {
        beginShutdown()
        await withCheckedContinuation { continuation in
            finished.notify(queue: .global()) { continuation.resume() }
        }
    }
}
