import Foundation

/// Playback time formatted as "0:42:15" or "4:05".
public enum TimeFormat {
    /// `withHours` aligns formatting with duration: "0:04:05" alongside "1:58:03".
    public static func string(_ seconds: Double, withHours: Bool = false) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours > 0 || withHours {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Remaining playback time with minus sign: "−1:15:48".
    public static func remaining(position: Double, duration: Double) -> String {
        let left = max(0, duration - position)
        return "−" + string(left, withHours: duration >= 3600)
    }

    /// Pair "elapsed / remaining" in unified format for a single duration.
    public static func elapsed(_ position: Double, duration: Double) -> String {
        string(position, withHours: duration >= 3600)
    }

    public static func format(_ seconds: Double?, withHours: Bool = false) -> String {
        guard let seconds, !seconds.isNaN, seconds >= 0 else { return "--:--" }
        return string(seconds, withHours: withHours)
    }

    public static func remaining(position: Double?, duration: Double?) -> String {
        guard let position, let duration, duration >= position else { return "--:--" }
        return "−" + string(duration - position, withHours: duration >= 3600)
    }

    public static func pair(position: Double?, duration: Double?) -> (
        elapsed: String, remaining: String
    ) {
        let withHours = (duration ?? 0) >= 3600
        return (
            format(position, withHours: withHours),
            remaining(position: position, duration: duration)
        )
    }
}
