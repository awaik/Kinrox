import Foundation

/// Inert unless separately authorized by the owner and enabled in the test environment.
@MainActor
enum SoloistProbeAudition {
    static func run(socket: SoloistProbeSocket, process: SoloistProbeProcess) async throws {
        guard ProcessInfo.processInfo.environment["KINROX_SOLOIST_AUDITION"] == "1" else {
            throw SoloistProbeFailure.invalidCommand
        }
        guard socket.loggedIn, socket.uri != nil, socket.volume == 0 else {
            throw SoloistProbeFailure.invalidCommand
        }
        do {
            let revision = socket.stateRevision
            let uri = socket.uri
            try await socket.send("play")
            try await socket.wait(seconds: 15) {
                socket.confirmedPlayingURI == uri && socket.stateRevision > revision
            }
            try await socket.send("set_volume", fields: ["volume": 5])
            try await socket.wait(seconds: 2) { socket.volume == 5 }
            try await Task.sleep(for: .seconds(5))
            try await socket.send("set_volume", fields: ["volume": 0])
            try await socket.wait(seconds: 2) { socket.volume == 0 }
            try await socket.send("pause")
            try await socket.wait(seconds: 2) { socket.status == "paused" }
        } catch {
            // If restoring mute cannot be confirmed, terminate the owned audio process.
            await process.stop()
            throw error
        }
    }
}
