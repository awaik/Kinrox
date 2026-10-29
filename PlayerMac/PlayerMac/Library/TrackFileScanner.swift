import Foundation

struct TrackScanUpdate: Sendable {
    var files: [TrackFile] = []
    var folders = 0
    var unreadableFolders = 0
}

enum TrackFileScanner {
    static let audioExtensions: Set<String> = [
        "mka", "m4a", "aac", "ac3", "eac3", "dts", "dtshd", "flac", "wav", "aif", "aiff",
        "mp3", "mp2", "mpa", "opus", "ogg", "oga", "wma", "weba",
    ]
    static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "sami", "ttml", "dfxp", "mks",
        "lrc",
    ]

    static func kind(for url: URL) -> MediaTrackKind? {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        return subtitleExtensions.contains(ext) ? .subtitle : nil
    }

    /// Runs off the main actor. The detached worker is cancelled when its consumer exits.
    static func scan(root: URL, video: URL, recursive: Bool) -> AsyncStream<TrackScanUpdate> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .utility) {
                let manager = FileManager.default
                let keys: Set<URLResourceKey> = [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                ]
                var update = TrackScanUpdate()
                var batch: [TrackFile] = []
                var lastYield = ContinuousClock.now
                var seen: Set<String> = []
                let root = root.standardizedFileURL.resolvingSymlinksInPath()
                guard
                    let walker = manager.enumerator(
                        at: root, includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        errorHandler: { _, _ in
                            update.unreadableFolders += 1
                            return !Task.isCancelled
                        }
                    )
                else {
                    update.unreadableFolders = 1
                    continuation.yield(update)
                    continuation.finish()
                    return
                }
                update.folders = 1
                while let url = walker.nextObject() as? URL {
                    if Task.isCancelled { break }
                    guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                    if values.isSymbolicLink == true || values.isPackage == true {
                        walker.skipDescendants()
                        continue
                    }
                    if values.isDirectory == true {
                        if recursive { update.folders += 1 } else { walker.skipDescendants() }
                    } else if values.isRegularFile == true, let kind = kind(for: url) {
                        // VobSub is one track, represented by the index plus its companion .sub file.
                        let isVobSubData =
                            url.pathExtension.lowercased() == "sub"
                            && manager.fileExists(
                                atPath: url.deletingPathExtension().appendingPathExtension("idx")
                                    .path)
                        if !isVobSubData, seen.insert(url.standardizedFileURL.path).inserted {
                            batch.append(
                                TrackFile(
                                    url: url.standardizedFileURL, kind: kind,
                                    relativePath: TrackFile.relativePath(url, root: root),
                                    matchesVideo: TrackFileMatcher.matches(url, video: video)))
                        }
                    }
                    if batch.count >= 64 || lastYield.duration(to: .now) > .milliseconds(100) {
                        update.files = batch
                        continuation.yield(update)
                        batch = []
                        lastYield = .now
                    }
                }
                if !Task.isCancelled {
                    update.files = batch
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
