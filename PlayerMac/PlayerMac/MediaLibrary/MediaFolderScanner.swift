import Foundation

enum MediaFolderScanner {
    struct Volume: Sendable {
        let uuid: String?
        let mountPath: String
        let removable: Bool
    }

    struct Dependencies: Sendable {
        var volume: @Sendable (URL) -> Volume? = { url in
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .volumeUUIDStringKey, .volumeURLKey, .volumeIsInternalKey,
                .volumeIsRemovableKey,
            ]
            guard FileManager.default.isReadableFile(atPath: url.path),
                let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true,
                let mount = values.volume
            else { return nil }
            return Volume(
                uuid: values.volumeUUIDString, mountPath: mount.path,
                removable: values.volumeIsRemovable == true || values.volumeIsInternal == false)
        }
    }

    enum Result { case ready, offline, incomplete }

    static func folder(_ url: URL, dependencies: Dependencies = Dependencies()) -> WatchedFolder? {
        guard url.isFileURL else { return nil }
        let path = VideoFiles.key(url)
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
        guard let volume = dependencies.volume(canonical), isMounted(canonical, volume: volume)
        else { return nil }
        return WatchedFolder(
            id: UUID(), path: path,
            displayName: canonical.lastPathComponent.isEmpty ? path : canonical.lastPathComponent,
            volumeUUID: volume.uuid, isRemovable: volume.removable || path.hasPrefix("/Volumes/"))
    }

    static func scan(
        _ folder: WatchedFolder, database: MediaLibraryDatabase, artwork: ArtworkCache,
        dependencies: Dependencies = Dependencies(), progress: @Sendable (Int) async -> Void
    ) async throws -> Result {
        let validate: @Sendable () -> Bool = {
            guard let volume = dependencies.volume(folder.url),
                isMounted(folder.url, volume: volume)
            else { return false }
            return folder.volumeUUID == nil || volume.uuid == folder.volumeUUID
        }
        guard validate() else {
            try await database.markOffline(folder.id)
            return .offline
        }

        let existing = try await database.stamps(folder.id)
        var missing = Set(existing.keys)
        let traversal = Traversal(folder.url)
        guard let enumerator = traversal.enumerator else {
            try Task.checkCancellation()
            return try await database.finishScan(folder.id, missing: [], validate: validate)
                ? .incomplete : .offline
        }
        var batch: [MediaLibraryFile] = []
        var count = 0
        let root = folder.url.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let attributes = try? url.resourceValues(forKeys: Traversal.keys) else {
                traversal.incomplete = true
                continue
            }
            if attributes.isSymbolicLink == true || attributes.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            if let uuid = folder.volumeUUID, let actual = attributes.volumeUUIDString,
                uuid != actual
            {
                enumerator.skipDescendants()
                continue
            }
            guard attributes.isRegularFile == true, url.pathExtension.lowercased() != "sub",
                LocalAudioFiles.isAudio(url) || VideoFiles.isVideo(url),
                let size = attributes.fileSize, let modified = attributes.contentModificationDate
            else { continue }
            let path = VideoFiles.key(url)
            guard path.hasPrefix(rootPrefix) else {
                traversal.incomplete = true
                continue
            }
            let stamp = MediaLibraryDatabase.Stamp(size: Int64(size), modified: modified)
            missing.remove(path)
            count += 1
            if existing[path] != stamp {
                batch.append(
                    MediaLibraryFile(
                        path: path, size: stamp.size, modified: modified, added: Date()))
            }
            if batch.count == 32 {
                guard validate() else {
                    try await database.markOffline(folder.id)
                    return .offline
                }
                guard
                    try await index(
                        batch, root: root, folder: folder.id, database: database, artwork: artwork,
                        validate: validate)
                else { return .offline }
                batch.removeAll(keepingCapacity: true)
            }
            if count.isMultiple(of: 32) { await progress(count) }
        }
        try Task.checkCancellation()
        guard validate() else {
            try await database.markOffline(folder.id)
            return .offline
        }
        guard
            try await index(
                batch, root: root, folder: folder.id, database: database, artwork: artwork,
                validate: validate)
        else { return .offline }
        await progress(count)
        try Task.checkCancellation()
        // Some network and removable formats do not expose a persistent volume
        // UUID. Keep unseen rows on these mounts and after incomplete traversal.
        let removableWithoutIdentity = folder.isRemovable && folder.volumeUUID == nil
        guard
            try await database.finishScan(
                folder.id, missing: traversal.incomplete || removableWithoutIdentity ? [] : missing,
                validate: validate)
        else { return .offline }
        return traversal.incomplete ? .incomplete : .ready
    }

    private static func isMounted(_ url: URL, volume: Volume) -> Bool {
        guard url.path.hasPrefix("/Volumes/") else { return true }
        let mount = URL(fileURLWithPath: volume.mountPath, isDirectory: true).standardizedFileURL
            .path
        return mount.hasPrefix("/Volumes/")
            && (url.path == mount || url.path.hasPrefix(mount + "/"))
    }

    private static func index(
        _ batch: [MediaLibraryFile], root: URL, folder: UUID, database: MediaLibraryDatabase,
        artwork: ArtworkCache,
        validate: @Sendable () -> Bool
    ) async throws -> Bool {
        guard !batch.isEmpty else { return true }
        let indexed = await withTaskGroup(
            of: MediaLibraryFile.self, returning: [MediaLibraryFile].self
        ) { group in
            var next = batch.makeIterator()
            var results: [MediaLibraryFile] = []
            for _ in 0..<4 {
                if let file = next.next() {
                    group.addTask { await read(file, root: root, artwork: artwork) }
                }
            }
            while let file = await group.next() {
                results.append(file)
                if let file = next.next() {
                    group.addTask { await read(file, root: root, artwork: artwork) }
                }
            }
            return results
        }
        try Task.checkCancellation()
        return try await database.apply(indexed, folder: folder, validate: validate)
    }

    private static func read(_ file: MediaLibraryFile, root: URL, artwork: ArtworkCache) async
        -> MediaLibraryFile
    {
        var indexed = file
        if LocalAudioFiles.isAudio(file.url) {
            let tags = await LocalAudioTagReader.read(file.url, artwork: artwork)
            indexed.audio = tags
        } else {
            indexed.video = VideoTitleParser.parse(file.url, root: root)
        }
        return indexed
    }

    /// FileManager delivers the enumeration error handler synchronously from nextObject.
    private final class Traversal: @unchecked Sendable {
        static let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
            .contentModificationDateKey,
            .volumeUUIDStringKey,
        ]
        var incomplete = false
        private(set) var enumerator: FileManager.DirectoryEnumerator?

        init(_ root: URL) {
            enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(Self.keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) { [weak self] _, _ in
                self?.incomplete = true
                return true
            }
        }
    }
}
