import Foundation

/// Coalesce only a trailing state. Critical events retain causal order with bounded backpressure.
actor SoloistEventBuffer {
    private var pending: [MusicEngineEvent] = []
    private var reader: CheckedContinuation<MusicEngineEvent?, Never>?
    private var writers: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    func send(_ event: MusicEngineEvent) async {
        guard !closed else { return }
        if let reader {
            self.reader = nil
            reader.resume(returning: event)
            return
        }
        if case .state = event, case .state = pending.last {
            pending[pending.count - 1] = event
            return
        }
        while pending.count >= 64, !closed {
            await withCheckedContinuation { writers.append($0) }
        }
        guard !closed else { return }
        if let reader {
            self.reader = nil
            reader.resume(returning: event)
        } else if case .state = event, case .state = pending.last {
            pending[pending.count - 1] = event
        } else {
            pending.append(event)
        }
    }

    func next() async -> MusicEngineEvent? {
        if !pending.isEmpty {
            let result = pending.removeFirst()
            if !writers.isEmpty { writers.removeFirst().resume() }
            return result
        }
        guard !closed else { return nil }
        return await withCheckedContinuation { reader = $0 }
    }

    func finish() {
        closed = true
        reader?.resume(returning: nil)
        reader = nil
        for writer in writers { writer.resume() }
        writers.removeAll()
    }
}
