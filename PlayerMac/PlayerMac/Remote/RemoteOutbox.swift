import Foundation
import RemoteProtocol

/// Single bounded queue per remote: initial state/recent and replies preserve order.
@MainActor
final class RemoteOutbox {
    var pendingCount: Int { messages.count }
    var onDrained: (() -> Void)?
    private var messages: [Message] = []
    private var task: Task<Void, Never>?
    private var closed = false
    private let send: (Message) async throws -> Void
    private let failed: () -> Void

    init(send: @escaping (Message) async throws -> Void, failed: @escaping () -> Void) {
        self.send = send
        self.failed = failed
    }

    func enqueue(_ message: Message) {
        guard !closed else { return }
        guard messages.count < 32 else {
            close()
            failed()
            return
        }
        messages.append(message)
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                while !self.closed, !self.messages.isEmpty {
                    let next = self.messages.removeFirst()
                    try await self.send(next)
                    if !self.closed { self.onDrained?() }
                }
                self.task = nil
            } catch {
                self.close()
                self.failed()
            }
        }
    }

    func close() {
        closed = true
        onDrained = nil
        messages.removeAll()
        task?.cancel()
        task = nil
    }
}
