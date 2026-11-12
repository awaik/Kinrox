import Foundation

extension MusicDiscoveryEngine {
    typealias Candidate = (item: MusicDiscoveryItem, signals: [MusicDiscoverySignal])

    static func deduplicate(_ scored: [Candidate], identities: inout DiscoveryIdentityIndex)
        -> [MusicDiscoveryItem]
    {
        // Slots are compact indices into the immutable score order. Merging reasons must
        // not repeatedly copy the complete track and its metadata for every token lookup.
        let tokens = scored.map { identities.identity($0.item.track).recordingTokens }
        var reasons = scored.map { candidate in
            candidate.signals.map {
                WeightedReason(reason: $0.reason, contribution: $0.contribution)
            }
        }
        var live = Array(repeating: false, count: scored.count)
        // Live representatives never share a token: an insertion merges every matching slot.
        var tokenSlots: [DiscoveryRecordingToken: Int] = [:]
        tokenSlots.reserveCapacity(scored.count * 4)
        for index in scored.indices {
            var matches: [Int] = []
            for token in tokens[index] {
                if let slot = tokenSlots[token], !matches.contains(slot) { matches.append(slot) }
            }
            matches.sort()
            guard let first = matches.first else {
                live[index] = true
                for token in tokens[index] { tokenSlots[token] = index }
                continue
            }
            reasons[first] = mergeReasons(reasons[index] + matches.flatMap { reasons[$0] })
            // The best representative keeps exactly its own tokens, as in the reference
            // algorithm. Candidate/loser tokens must not make future matches transitive.
            for loser in matches.dropFirst() {
                for token in tokens[loser] { tokenSlots[token] = nil }
                live[loser] = false
            }
        }
        return scored.indices.compactMap { index in
            guard live[index] else { return nil }
            return MusicDiscoveryItem(
                track: scored[index].item.track, reasons: reasons[index].map(\.reason),
                score: scored[index].item.score)
        }
    }

    private struct WeightedReason {
        let reason: MusicDiscoveryReason
        let contribution: Double
    }

    /// Track selection and scoring are already final. Variant merging only combines reasons,
    /// so copying complete MusicTrack payloads here cannot affect the winner or its score.
    private static func mergeReasons(_ values: [WeightedReason]) -> [WeightedReason] {
        var groups: [WeightedReason] = []
        for value in values {
            if let index = groups.firstIndex(where: { $0.reason.kind == value.reason.kind }) {
                let existing = groups[index]
                let lhs = existing.reason.detail
                let rhs = value.reason.detail
                let detail =
                    lhs.count == rhs.count ? min(lhs, rhs) : (lhs.count > rhs.count ? lhs : rhs)
                groups[index] = WeightedReason(
                    reason: .init(
                        kind: value.reason.kind, detail: detail,
                        matchCount: max(existing.reason.matchCount, value.reason.matchCount)),
                    contribution: max(existing.contribution, value.contribution))
            } else {
                groups.append(value)
            }
        }
        return groups.sorted {
            $0.contribution == $1.contribution
                ? $0.reason.kind.rawValue < $1.reason.kind.rawValue
                : $0.contribution > $1.contribution
        }
    }

    static func diversify(
        _ items: [MusicDiscoveryItem], identities: inout DiscoveryIdentityIndex,
        seedIDs: Set<String>, seedNames: Set<String>
    ) -> [MusicDiscoveryItem] {
        let metadata = items.map { identities.identity($0.track) }
        let seedCredits = items.map { item in
            item.track.artists.compactMap { artist -> String? in
                let name = identities.normalized(artist.name)
                return seedIDs.contains(artist.id) || seedNames.contains(name) ? name : nil
            }
        }
        var ordered: [MusicDiscoveryItem] = []
        var primaryCounts: [String: Int] = [:]
        var seedCounts: [String: Int] = [:]
        var selectedIDs = Set<String>()
        var selectedNames = Set<String>()
        var scores = items.map(\.score)
        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
            if items[lhs].score != items[rhs].score { return items[lhs].score > items[rhs].score }
            let l = metadata[lhs]
            let r = metadata[rhs]
            return l.stableHash == r.stableHash ? l.id < r.id : l.stableHash < r.stableHash
        }
        var heap: [Int] = []
        func push(_ index: Int) {
            heap.append(index)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }
        func pop() -> Int? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let result = heap[0]
            heap[0] = heap.removeLast()
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, precedes(heap[child + 1], heap[child]) { child += 1 }
                guard precedes(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                parent = child
            }
            return result
        }
        for index in items.indices { push(index) }
        var deferred: [Int] = []
        var primaryLimit = 2
        while !heap.isEmpty || !deferred.isEmpty {
            if heap.isEmpty {
                deferred.removeAll { index in
                    !seedCredits[index].allSatisfy { seedCounts[$0, default: 0] < 3 }
                }
                guard
                    let least = deferred.map({
                        primaryCounts[metadata[$0].primaryArtistKey, default: 0]
                    }).min()
                else { break }
                primaryLimit = least + 1
                let pending = deferred
                deferred = []
                for index in pending { push(index) }
            }
            guard let index = pop() else { break }
            guard seedCredits[index].allSatisfy({ seedCounts[$0, default: 0] < 3 }) else {
                continue
            }
            if ordered.count < 30,
                primaryCounts[metadata[index].primaryArtistKey, default: 0] >= primaryLimit
            {
                deferred.append(index)
                continue
            }
            // Scores only decrease once. A stale heap key is an upper bound, so lazy
            // correction produces exactly the reference greedy maximum without scanning all pairs.
            let score =
                items[index].score
                * (metadata[index].sharesArtist(ids: selectedIDs, names: selectedNames) ? 0.8 : 1)
            if score != scores[index] {
                scores[index] = score
                push(index)
                continue
            }
            ordered.append(items[index])
            primaryCounts[metadata[index].primaryArtistKey, default: 0] += 1
            for name in seedCredits[index] { seedCounts[name, default: 0] += 1 }
            selectedIDs.formUnion(metadata[index].artistIDs)
            selectedNames.formUnion(metadata[index].artistNormNames)
            if ordered.count == 30 {
                for index in deferred { push(index) }
                deferred = []
            }
        }
        return ordered
    }
}
