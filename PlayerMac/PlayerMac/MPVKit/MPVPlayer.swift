import Foundation

@MainActor
final class MPVPlayer: PlayerEngine {
    let events: AsyncStream<PlaybackEvent>
    var videoLayer: VideoLayer { lifetime.videoLayer }
    private let lifetime: MPVLifetime
    private var isClosing = false
    private static let configureLocale: Void = { setlocale(LC_NUMERIC, "C") }()

    init() throws {
        // Executes sequentially on MainActor, prior to creating any mpv core.
        _ = Self.configureLocale
        guard let handle = mpv_create() else { throw MPVError("Failed to create libmpv player.") }
        let stream = AsyncStream<PlaybackEvent>.makeStream()
        events = stream.stream
        do {
            let options = [
                ("vo", "libmpv"), ("hwdec", "auto-safe"), ("keep-open", "yes"),
                ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
                ("input-media-keys", "no"), ("osc", "no"), ("ytdl", "no"),
                ("load-scripts", "no"), ("config", "no"), ("volume-max", "100"),
                // load-scripts disables user scripts, but built-ins have separate
                // switches. Their LuaJIT code is unnecessary for Kinrox's native UI
                // and cannot run under Hardened Runtime without executable-memory exemptions.
                ("load-stats-overlay", "no"), ("load-console", "no"),
                ("load-auto-profiles", "no"), ("load-select", "no"),
                ("load-positioning", "no"), ("load-commands", "no"),
                ("load-context-menu", "no"),
                ("video-timing-offset", "0"),
            ]
            for (name, value) in options {
                try MPVError.check(mpv_set_option_string(handle, name, value), "Option \(name)")
            }
            try MPVError.check(mpv_request_log_messages(handle, "warn"), "Enabling logs")
            for (index, property) in PlaybackProperty.allCases.enumerated() {
                try MPVError.check(
                    mpv_observe_property(
                        handle, UInt64(index + 1), property.rawValue,
                        property.mpvFormat), "Observing \(property.rawValue)")
            }
            try MPVError.check(mpv_initialize(handle), "libmpv initialization")
            let renderer = try MPVRenderContext(handle: handle)
            let layer = VideoLayer(resources: renderer)
            let loop = MPVEventLoop(handle: handle, continuation: stream.continuation)
            lifetime = MPVLifetime(handle: handle, eventLoop: loop, videoLayer: layer)
            loop.start()
        } catch {
            stream.continuation.finish()
            mpv_terminate_destroy(handle)
            throw error
        }
    }

    deinit { lifetime.beginShutdown() }

    func load(url: URL) throws {
        guard url.isFileURL else { throw MPVError("Only local files can be opened.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw MPVError("Select a video file.") }
        try command(["loadfile", url.path, "replace"])
        try setPaused(false)
    }

    func setPaused(_ paused: Bool) throws { try command(["set", "pause", paused ? "yes" : "no"]) }

    func seek(relative seconds: Double) throws {
        guard seconds.isFinite else { throw MPVError("Invalid position.") }
        try command(["seek", String(seconds), "relative+keyframes"])
    }

    func seek(absolute seconds: Double) throws {
        guard seconds.isFinite else { throw MPVError("Invalid position.") }
        try command(["seek", String(max(0, seconds)), "absolute+exact"])
    }

    func setVolume(_ volume: Double) throws {
        guard volume.isFinite else { throw MPVError("Invalid volume.") }
        try command(["set", "volume", String(min(100, max(0, volume)))])
    }

    func stop() throws { try command(["stop"]) }

    func shutdown() async {
        isClosing = true
        await lifetime.waitForShutdown()
    }

    private func command(_ arguments: [String]) throws {
        guard !isClosing else { throw MPVError("Player is already shutting down.") }
        let strings = arguments.map { strdup($0) }
        defer {
            for string in strings { free(string) }
        }
        var pointers = strings.map { $0.map { UnsafePointer($0) } } + [nil]
        // Response arrives via COMMAND_REPLY; UI does not block on rendering core.
        try MPVError.check(mpv_command_async(lifetime.handle, 0, &pointers), "Player command")
    }
}
