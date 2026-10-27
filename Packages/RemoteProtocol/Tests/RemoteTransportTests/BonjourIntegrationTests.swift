import Foundation
import RemoteProtocol
import Testing

@testable import RemoteTransport

@Suite("Bonjour in local.", .serialized)
@MainActor struct BonjourIntegrationTests {
    @Test("TXT discovery, connecting to service endpoint, advertisement removal")
    func discoverConnectRemove() async throws {
        let h = try TransportHarness()
        let browser = BonjourBrowser()
        defer {
            browser.stop()
            h.stop()
        }
        browser.start()
        try await h.start(advertise: true)
        try await eventually(timeout: .seconds(10)) {
            if case .failed(let error) = browser.state { throw error }
            if case .waiting(let error) = browser.state { throw error }
            return browser.servers.contains { $0.id == h.id && $0.isAvailable }
        }
        let found = try #require(browser.servers.first { $0.id == h.id })
        #expect(found.appVersion == "1.0" && found.protocolVersion == 1)
        let device = UUID()
        var token: Data?
        let client = try TransportClient(
            server: found, deviceId: device,
            deviceName: "Bonjour-test", appVersion: "1.0", mode: .pair, saveToken: { token = $0 })
        defer { client.close() }
        client.start()
        try await eventually {
            if case .closed(let failure) = client.state { throw failure }
            return client.state == .awaitingPIN && h.pins[device] != nil
        }
        try await client.submitPIN(try #require(h.pins[device]))
        try await eventually { client.state == .connected }
        #expect(token?.count == 32)
        h.server.stop()
        try await eventually(timeout: .seconds(10)) {
            browser.servers.contains { $0.id == h.id && !$0.isAvailable }
        }
        #expect(browser.servers.contains { $0.id == h.id })
    }
}
