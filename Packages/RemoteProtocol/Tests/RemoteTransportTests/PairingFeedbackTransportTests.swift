import Foundation
import RemoteProtocol
import Testing

@testable import RemoteTransport

@Suite("Propagating server PIN errors to UI")
@MainActor struct PairingFeedbackTransportTests {
    @Test("TransportClient transmits text and replyTo before retryPIN")
    func feedback() async throws {
        let harness = try TransportHarness()
        defer { harness.stop() }
        try await harness.start()
        let device = UUID()
        let client = harness.client(deviceId: device)
        var errors: [ProtocolError] = []
        var events: [String] = []
        client.onEvent = {
            switch $0 {
            case .protocolError(let error):
                errors.append(error)
                events.append("error")
            case .retryPIN: events.append("retry")
            default: break
            }
        }
        try await eventually { client.state == .awaitingPIN && harness.pins[device] != nil }
        let pin = try #require(harness.pins[device])
        try await client.submitPIN(pin == "000000" ? "111111" : "000000")
        try await eventually { events.count == 2 }
        #expect(events == ["error", "retry"])
        #expect(errors.first?.message == "Incorrect code, attempts remaining: 2")
        #expect(errors.first?.replyTo != nil)
        #expect(client.state == .awaitingPIN)
        try await client.submitPIN(pin)
        try await eventually { client.state == .connected }
    }
}
