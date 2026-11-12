import Foundation

/// A value-only worker. Cancellation retires the detached task and rejects its result.
enum MusicDiscoveryComputation {
    nonisolated static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = autoreleasepool(invoking: operation)
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }
}
