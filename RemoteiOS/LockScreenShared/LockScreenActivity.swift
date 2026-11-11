import ActivityKit
import AppIntents
import Foundation

/// Lock Screen and Dynamic Island card (Figma 13 · Remote — Lock Screen, `212:304`).
/// Compiled into the app and the widget extension; buttons run in the app process.
struct LockScreenAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Media: String, Codable, Hashable, Sendable { case music, video }
        enum Phase: String, Codable, Hashable, Sendable { case live, sending, unreachable }

        var media: Media
        var title: String
        var subtitle: String
        var macName: String
        var paused: Bool
        /// Position measured at `anchor`; playing cards extrapolate with system timers.
        var position: Double
        var duration: Double
        var anchor: Date
        var phase = Phase.live
        var sending: LockScreenAction?
        var canPrevious: Bool
        var canNext: Bool
        var canVolume: Bool
        var nextTitle: String?
        var nextSubtitle: String?
        /// Survives process termination without restarting the one-hour pause limit.
        var pausedSince: Date?

        /// Playback start implied by the anchor; used for timer-driven progress.
        var startDate: Date { anchor.addingTimeInterval(-position) }
        var endDate: Date { startDate.addingTimeInterval(max(duration, position, 1)) }
        var showsTimer: Bool { !paused && phase != .unreachable && duration > 0 }
    }
}

/// The card and expanded Dynamic Island present the same unavailable and stale states.
struct LockScreenPresentation {
    let title: String
    let subtitle: String
    let showsNext: Bool

    init(state: LockScreenAttributes.ContentState, isStale: Bool) {
        showsNext =
            isStale && state.phase == .live && state.media == .music
            && state.nextTitle != nil
        if state.phase == .unreachable {
            title = L10n.text("Mac unavailable")
            subtitle = L10n.text("Open Kinrox Remote")
        } else {
            title = showsNext ? state.nextTitle ?? state.title : state.title
            subtitle = showsNext ? state.nextSubtitle ?? state.subtitle : state.subtitle
        }
    }
}

/// Every Lock Screen button. Video uses ±10 s instead of previous/next.
enum LockScreenAction: String, Codable, Hashable, Sendable, AppEnum {
    case previous, togglePause, next, back10, forward10, volumeDown, volumeUp

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kinrox control"
    static let caseDisplayRepresentations: [LockScreenAction: DisplayRepresentation] = [
        .previous: "Previous track", .togglePause: "Play/Pause", .next: "Next track",
        .back10: "Back 10 seconds", .forward10: "Forward 10 seconds",
        .volumeDown: "Volume down", .volumeUp: "Volume up",
    ]
}

/// Runs in the app process, so it can reconnect to the Mac without opening the remote.
struct LockScreenControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control Kinrox"
    static let isDiscoverable = false

    @Parameter(title: "Action") var action: LockScreenAction

    init() {}
    init(_ action: LockScreenAction) { self.action = action }

    func perform() async throws -> some IntentResult {
        await LockScreenCommands.perform(action)
        return .result()
    }
}

/// The app registers the handler at launch; the extension never does.
@MainActor
enum LockScreenCommands {
    static var handler: (@MainActor (LockScreenAction) async -> Void)?

    static func perform(_ action: LockScreenAction) async {
        await handler?(action)
    }
}
