import Foundation
import MusicCore

extension LocalAudioViewModel {
    func setShuffle(_ value: Bool) {
        guard queue.shuffled != value else { return }
        mutateQueue { queue in
            var random = SystemRandomNumberGenerator()
            queue.setShuffle(value, using: &random)
            return true
        }
    }

    func setRepeat(_ mode: MusicRepeat) {
        guard queue.repeatMode != mode else { return }
        mutateQueue { queue in
            queue.repeatMode = mode
            return true
        }
    }

    @discardableResult
    func moveQueue(_ id: UUID, before target: UUID) -> Bool {
        mutateQueue { $0.move(id, before: target) }
    }

    @discardableResult
    func removeFromQueue(_ id: UUID) -> Bool {
        mutateQueue { $0.remove(id) }
    }

    static func formatBadge(for track: LocalAudioTrack) -> String {
        let base = track.format.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if let depth = track.file.audio?.bitDepth, let rate = track.file.audio?.sampleRate,
            depth > 0, rate > 0
        {
            let rateText: String
            if rate.isMultiple(of: 1000) {
                rateText = String(rate / 1000)
            } else {
                rateText = String(
                    format: "%.1f", locale: Locale(identifier: "en_US_POSIX"),
                    Double(rate) / 1000)
            }
            raw = base.isEmpty ? "\(depth)/\(rateText)" : "\(base) · \(depth)/\(rateText)"
        } else {
            raw = base
        }
        return RemoteLibraryBridge.truncateUTF8(raw, maxBytes: 64)
    }
}
