import Foundation
import RemoteProtocol
import RemoteTransport
import UIKit
import XCTest

@testable import RemoteiOS

/// Opt-in physical-device measurement. Uses existing pairing and never records metadata or tokens.
@MainActor
final class SoloistLANAcceptanceTests: XCTestCase {
    func testPhysicalPhoneCommandsAtZeroGain() async throws {
        guard ProcessInfo.processInfo.environment["KINROX_SOLOIST_LAN_LIVE"] == "1" else {
            throw XCTSkip("Physical LAN acceptance is explicitly opt-in.")
        }
        #if targetEnvironment(simulator)
            throw XCTSkip("A simulator is not physical iPhone acceptance.")
        #else
            let iterations = min(
                200,
                max(
                    10,
                    Int(ProcessInfo.processInfo.environment["KINROX_SOLOIST_LAN_COUNT"] ?? "10")
                        ?? 10))
            let idleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = idleTimerDisabled }
            let observer = LANObservation()
            let model = RemoteAppModel { server, deviceID, mode, save in
                let client = try TransportClient(
                    server: server, deviceId: deviceID, deviceName: UIDevice.current.name,
                    appVersion: "acceptance", mode: mode, saveToken: save)
                return ObservedLANConnection(client: client, observer: observer)
            }
            model.start()
            defer { model.stop() }
            try await wait(seconds: 30) { model.controlsEnabled }
            guard model.state.source == .music, model.state.hasMedia,
                model.state.volume == 0, model.state.music?.volumeKnown == true,
                !model.state.paused, model.state.music?.queueCount ?? 0 >= 12
            else { throw LANFailure.precondition }
            let originalRepeat = model.state.music?.repeatMode ?? .off
            defer {
                let attachment = XCTAttachment(
                    data: (try? JSONEncoder().encode(observer.samples)) ?? Data(),
                    uniformTypeIdentifier: "public.json")
                attachment.name = "soloist-lan-latency-ms"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            do {
                if iterations > 10 {
                    try await command(
                        "repeat_setup", .setRepeat(repeatMode: .all), model, observer
                    ) { $0.music?.repeatMode == .all }
                }
                for index in 0..<iterations {
                    try await command("pause", .setPaused(paused: true), model, observer) {
                        $0.paused
                    }
                    try await command("resume", .setPaused(paused: false), model, observer) {
                        !$0.paused
                    }
                    let target = index.isMultiple(of: 2) ? 20.0 : 10.0
                    try await command(
                        "seek", .seekAbsolute(seconds: target), model, observer
                    ) { !$0.paused && abs($0.position - target) < 1.5 }
                    // Idempotent zero gain: fresh state evidence, not a gain-change measurement.
                    try await command("volume_zero", .setVolume(volume: 0), model, observer) {
                        $0.music?.volumeKnown == true
                    }
                    let previous = model.state.music?.track?.id
                    try await command("next", .next, model, observer) {
                        !$0.paused && $0.music?.track?.id != previous
                            && $0.music?.volumeKnown == true
                            && $0.music?.disallowedActions?.contains("pausing") != true
                    }
                }
                try await command("final_pause", .setPaused(paused: true), model, observer) {
                    $0.paused
                }
                if iterations > 10 {
                    try await command(
                        "repeat_restore", .setRepeat(repeatMode: originalRepeat), model, observer
                    ) { $0.music?.repeatMode == originalRepeat }
                }
            } catch let failure {
                model.send(.setPaused(paused: true))
                if iterations > 10 { model.send(.setRepeat(repeatMode: originalRepeat)) }
                try? await Task.sleep(for: .seconds(1))
                throw failure
            }
        #endif
    }

    private func command(
        _ name: String, _ command: Command, _ model: RemoteAppModel,
        _ observer: LANObservation, confirmed: @escaping (PlayerState) -> Bool
    ) async throws {
        // Match the actual UI: wait for the previous transition to re-enable this command.
        try await wait(seconds: 18) {
            guard model.controlsEnabled else { return false }
            guard
                let action = command.musicAction(
                    paused: model.state.paused, repeatMode: model.state.music?.repeatMode ?? .off)
            else { return true }
            return model.musicAllows(action)
        }
        guard model.state.volume == 0 else { throw LANFailure.precondition }
        let began = ContinuousClock.now
        var accepted: Bool?
        var ack: ContinuousClock.Instant?
        var observed: ContinuousClock.Instant?
        observer.received = { state in
            if state.source == .music, state.volume == 0, confirmed(state), observed == nil {
                observed = .now
            }
        }
        defer { observer.received = nil }
        let id = model.send(command) { value in
            accepted = value
            ack = .now
        }
        do {
            guard id != nil else { throw LANFailure.rejected }
            try await wait(seconds: 18) {
                accepted == false || (accepted == true && observed != nil)
            }
            guard accepted == true, let ack, let observed else { throw LANFailure.rejected }
            observer.samples.append(
                .init(
                    operation: name, acceptedMS: milliseconds(began.duration(to: ack)),
                    observedMS: milliseconds(began.duration(to: observed)), failure: nil))
        } catch {
            observer.samples.append(
                .init(
                    operation: name, acceptedMS: ack.map { milliseconds(began.duration(to: $0)) },
                    observedMS: observed.map { milliseconds(began.duration(to: $0)) },
                    failure: accepted == false ? "rejected" : "timeout"))
            throw error
        }
    }

    private func wait(seconds: Double, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw LANFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

private enum LANFailure: Error { case precondition, rejected, timeout }

@MainActor
private final class LANObservation {
    struct Sample: Encodable {
        let operation: String
        let acceptedMS: Double?
        let observedMS: Double?
        let failure: String?
    }
    var samples: [Sample] = []
    var received: ((PlayerState) -> Void)?
}

@MainActor
private final class ObservedLANConnection: RemoteConnection {
    var onStateChange: ((TransportClient.State) -> Void)?
    var onEvent: ((TransportClient.Event) -> Void)?
    private let client: TransportClient

    init(client: TransportClient, observer: LANObservation) {
        self.client = client
        client.onStateChange = { [weak self] state in self?.onStateChange?(state) }
        client.onEvent = { [weak self] event in
            self?.onEvent?(event)
            if case .message(.state(_, let state)) = event { observer.received?(state) }
        }
    }
    func start() { client.start() }
    func submitPIN(_ pin: String) async throws { try await client.submitPIN(pin) }
    func send(_ message: Message) async throws { try await client.send(message) }
    func close(_ failure: TransportFailure) { client.close(failure) }
}
