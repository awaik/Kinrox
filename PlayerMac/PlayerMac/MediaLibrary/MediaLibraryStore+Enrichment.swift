import Foundation

extension MediaLibraryStore {
    func stopEnrichment() {
        enrichmentGeneration = UUID()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        pendingEnrichment = false
    }

    func scheduleEnrichment(refresh: Bool) {
        guard enrichMetadata else { return }
        if refresh { stopEnrichment() }
        guard enrichmentTask == nil else {
            pendingEnrichment = true
            return
        }
        var unique: Set<String> = []
        let jobs = snapshot.files.compactMap { file -> (String, MediaLibraryFile)? in
            guard !snapshot.offlinePaths.contains(file.path),
                let key = file.metadataKey, unique.insert(key).inserted
            else { return nil }
            if let cached = snapshot.metadata[key],
                !refresh, !cached.notFound || Date().timeIntervalSince(cached.fetched) < 7 * 86_400
            {
                return nil
            }
            return (key, file)
        }
        guard !jobs.isEmpty else { return }
        let generation = enrichmentGeneration
        enrichmentTask = Task { [weak self] in
            for (key, file) in jobs {
                guard let self, self.enrichMetadata, !Task.isCancelled,
                    self.enrichmentGeneration == generation
                else { return }
                await self.enrich(file, key: key, generation: generation, refresh: refresh)
            }
            guard let self, self.enrichmentGeneration == generation else { return }
            self.enrichmentTask = nil
            if self.pendingEnrichment {
                self.pendingEnrichment = false
                self.scheduleEnrichment(refresh: false)
            }
        }
    }

    private func enrich(_ file: MediaLibraryFile, key: String, generation: UUID, refresh: Bool)
        async
    {
        do {
            try Task.checkCancellation()
            var metadata: MediaEnrichment?
            if let video = file.video {
                metadata = try await videoClient.lookup(video)
            } else if let tags = file.audio, let album = tags.album,
                let artist = tags.albumArtist ?? tags.artist
            {
                if let match = try await musicClient.resolveAlbum(
                    album: album, artist: artist, refresh: refresh)
                {
                    metadata = MediaEnrichment(
                        rating: match.rating, source: .musicBrainz, year: match.year,
                        genres: match.genres, posterURL: match.coverArtURL)
                }
            }
            if var result = metadata, let url = result.posterURL,
                file.kind == .video || file.audio?.artworkPath == nil
            {
                try Task.checkCancellation()
                result.posterPath = try? await artwork.fetch(url)
                metadata = result
            }
            try Task.checkCancellation()
            guard enrichMetadata, enrichmentGeneration == generation else { return }
            let result = metadata ?? MediaEnrichment(notFound: true)
            try await database.save(result, key: key, kind: file.kind)
            guard enrichMetadata, enrichmentGeneration == generation else { return }
            snapshot.metadata[key] = result
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.debug(
                "Metadata lookup unavailable: \(error.localizedDescription, privacy: .private)")
        }
    }
}
