import Foundation

extension Command {
    public func musicAction(paused: Bool, repeatMode: RemoteMusicRepeat) -> String? {
        switch self {
        case .togglePause: return paused ? "resuming" : "pausing"
        case .setPaused(let value): return value ? "pausing" : "resuming"
        case .seekRelative, .seekAbsolute: return "seeking"
        case .next: return "skipping_next"
        case .previous: return "skipping_prev"
        case .setVolume: return "volume"
        case .setShuffle: return "toggling_shuffle"
        case .setRepeat(let value):
            return value == .one || repeatMode == .one
                ? "toggling_repeat_track" : "toggling_repeat_context"
        case .queueMove, .queueRemove: return paused ? nil : "interrupting_playback"
        default: return nil
        }
    }
}
