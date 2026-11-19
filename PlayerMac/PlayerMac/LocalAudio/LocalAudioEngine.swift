import Foundation
import OSLog
import UniformTypeIdentifiers

enum LocalAudioEvent: Sendable {
    case loaded(UUID)
    case ended(UUID)
    case failed(UUID, String)
    case paused(Bool)
    case position(Double)
    case duration(Double)
}

enum LocalAudioFailure: LocalizedError {
    case invalidFile
    case loadTimeout
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile: "Select a local audio file."
        case .loadTimeout: "Local audio timed out while loading."
        case .engine(let message): message
        }
    }

    static func alertMessage(for error: any Error) -> String {
        switch error as? Self {
        case .invalidFile: return L10n.text("Choose a video or local audio file.")
        case .loadTimeout: return L10n.text("Local audio took too long to open.")
        default:
            Logger(subsystem: "app.kinrox.player", category: "LocalAudio").error(
                "Playback failed: \(error.localizedDescription, privacy: .private)")
            return L10n.text("Mac could not complete request. Try again.")
        }
    }
}

@MainActor
protocol LocalAudioEngine: AnyObject {
    var events: AsyncStream<LocalAudioEvent> { get }
    func load(_ url: URL, id: UUID, position: Double) throws
    func setPaused(_ paused: Bool) throws
    func seek(_ position: Double) throws
    func setVolume(_ volume: Double) throws
    func shutdown() async
}

enum LocalAudioFiles {
    static let extensions: Set<String> = [
        "flac", "alac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "ogg", "oga", "opus",
    ]
    static var contentTypes: [UTType] {
        extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }
    static func isAudio(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }
}
