import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport

@Suite("Local transport policies")
struct TransportPolicyTests {
    @Test("Parameters forbid cellular and external incoming connections")
    func parameters() throws {
        for server in [false, true] {
            let parameters = TransportConfiguration.parameters(listener: server)
            #expect(parameters.acceptLocalOnly == server)
            #expect(parameters.prohibitedInterfaceTypes == [.cellular])
            #expect(!parameters.includePeerToPeer)
            #expect(parameters.preferNoProxies)
        }
        #expect(TransportConfiguration.maximumClients == 4)
    }

    @Test(
        "Ping every 5 seconds, exact boundary 15/20, reply extends deadline",
        arguments: [false, true])
    func heartbeat(_ server: Bool) {
        let start = ContinuousClock.now
        let timeout =
            server ? TransportConfiguration.serverTimeout : TransportConfiguration.clientTimeout
        var beat = Heartbeat(
            now: start, interval: TransportConfiguration.pingInterval, timeout: timeout)
        #expect(beat.tick(at: start.advanced(by: .seconds(4))) == .none)
        #expect(beat.tick(at: start.advanced(by: .seconds(5))) == .ping)
        #expect(beat.tick(at: start.advanced(by: .seconds(6))) == .none)
        #expect(beat.tick(at: start.advanced(by: .seconds(10))) == .ping)
        #expect(beat.tick(at: start.advanced(by: timeout)) == .timeout)
        beat.received(at: start.advanced(by: timeout))
        #expect(beat.tick(at: start.advanced(by: timeout + .seconds(5))) == .ping)
        #expect(beat.tick(at: start.advanced(by: timeout + timeout)) == .timeout)
    }

    @Test(
        "IPv4: subnet takes precedence over private range",
        arguments: [
            ("192.168.5.1", true), ("192.168.5.254", true), ("192.168.6.1", false),
            ("10.1.1.1", false), ("8.8.8.8", false), ("127.0.0.1", true),
            ("0.0.0.0", false), ("255.255.255.255", false), ("224.0.0.251", false),
            ("192.168.5.255", false), ("127.0.0.2", true), ("127.0.0.1%lo0", true),
            ("192.168.5.7%en0", true),
        ])
    func ipv4(_ address: String, _ allowed: Bool) {
        let subnet = LocalNetworkPolicy.Subnet(
            address: IPv4Address("192.168.5.20")!.rawValue,
            mask: IPv4Address("255.255.255.0")!.rawValue, interface: "en0")
        #expect(
            LocalNetworkPolicy.permits(
                .hostPort(host: .ipv4(IPv4Address(address)!), port: 1), subnets: [subnet])
                == allowed)
    }

    @Test(
        "IPv6: ULA/global subnet, multicast, mapped IPv4",
        arguments: [
            ("fd00:1234::2", true), ("fd00:4321::2", false),
            ("2001:db8:1::7", true), ("2001:db8:2::7", false),
            ("::1", true), ("::", false), ("ff02::fb", false),
            ("::ffff:192.168.5.2", true), ("::ffff:8.8.8.8", false),
            ("fe80::7", false), ("fe80::7%en0", true), ("fe80::7%lo0", false),
            ("::1%lo0", true),
        ])
    func ipv6(_ address: String, _ allowed: Bool) {
        let subnets = [
            LocalNetworkPolicy.Subnet(
                address: IPv6Address("fe80::1")!.rawValue,
                mask: IPv6Address("ffff:ffff:ffff:ffff::")!.rawValue, interface: "en0"),
            LocalNetworkPolicy.Subnet(
                address: IPv6Address("fd00:1234::1")!.rawValue,
                mask: IPv6Address("ffff:ffff:ffff:ffff::")!.rawValue, interface: "en0"),
            LocalNetworkPolicy.Subnet(
                address: IPv6Address("2001:db8:1::1")!.rawValue,
                mask: IPv6Address("ffff:ffff:ffff:ffff::")!.rawValue, interface: "en0"),
            LocalNetworkPolicy.Subnet(
                address: IPv4Address("192.168.5.1")!.rawValue,
                mask: IPv4Address("255.255.255.0")!.rawValue, interface: "en0"),
        ]
        #expect(
            LocalNetworkPolicy.permits(
                .hostPort(host: .ipv6(IPv6Address(address)!), port: 1), subnets: subnets) == allowed
        )
    }

    @Test("Scope does not turn unspecified/broadcast into valid address")
    func scopedSpecialAddresses() {
        for text in ["0.0.0.0%en0", "255.255.255.255%en0"] {
            let address = IPv4Address(text)!
            let subnet = LocalNetworkPolicy.Subnet(
                address: address.rawValue, mask: IPv4Address("255.255.255.255")!.rawValue,
                interface: "en0")
            #expect(
                !LocalNetworkPolicy.permits(
                    .hostPort(host: .ipv4(address), port: 1), subnets: [subnet]))
        }
        let address = IPv6Address("::%en0")!
        let subnet = LocalNetworkPolicy.Subnet(
            address: address.rawValue, mask: IPv6Address("ffff:ffff:ffff:ffff::")!.rawValue,
            interface: "en0")
        #expect(
            !LocalNetworkPolicy.permits(
                .hostPort(host: .ipv6(address), port: 1), subnets: [subnet]))
    }

    @Test("Task cancellation preserves close reason")
    func cancellationFailure() {
        #expect(TransportFailure.wrapping(CancellationError()) == .closed)
    }

    @Test("No address, name, or mask means no permission")
    func unresolved() {
        let subnet = LocalNetworkPolicy.Subnet(
            address: Data(repeating: 0, count: 4), mask: Data(repeating: 0, count: 4),
            interface: "en0")
        #expect(!LocalNetworkPolicy.permits(nil))
        #expect(!LocalNetworkPolicy.permits(.hostPort(host: .name("example.com", nil), port: 80)))
        #expect(
            !LocalNetworkPolicy.permits(
                .hostPort(host: .ipv4(IPv4Address("8.8.8.8")!), port: 80), subnets: [subnet]))
        #expect(!LocalNetworkPolicy.activeSubnets().isEmpty)
    }

    @Test("TXT and Bonjour domain pin server without proving authenticity")
    func advertisement() throws {
        let id = UUID()
        let advertisement = try BonjourAdvertiser(serverId: id, name: "Mac", appVersion: "1.2")
        let record = try #require(advertisement.service.txtRecordObject)
        #expect(record["id"] == id.uuidString)
        #expect(record["v"] == "1")
        #expect(record["pv"] == "1.2")
        let endpoint = NWEndpoint.service(
            name: "Mac", type: "_kinrox._tcp", domain: "local.", interface: nil)
        let discovered = try #require(DiscoveredServer(endpoint: endpoint, record: record))
        #expect(discovered.id == id && discovered.isAvailable)
        #expect(discovered.endpoint == endpoint)
        var changed = record
        changed["v"] = "2"
        #expect(DiscoveredServer(endpoint: endpoint, record: changed)?.protocolVersion == 2)
        for invalid in ["", "-1", "0", "4294967296", "abc"] {
            changed["v"] = invalid
            #expect(DiscoveredServer(endpoint: endpoint, record: changed) == nil)
        }
        changed = record
        changed["id"] = "invalid"
        #expect(DiscoveredServer(endpoint: endpoint, record: changed) == nil)
        #expect(
            DiscoveredServer(
                endpoint: .service(
                    name: "Mac", type: "_kinrox._tcp", domain: "example.com.", interface: nil),
                record: record) == nil)
        #expect(throws: TransportFailure.self) {
            try BonjourAdvertiser(serverId: id, name: "", appVersion: "1")
        }
        #expect(throws: TransportFailure.self) {
            try BonjourAdvertiser(
                serverId: id, name: "Mac", appVersion: String(repeating: "a", count: 253))
        }
    }

    @Test("Service disappearance keeps unavailable item; retry restores it")
    @MainActor func discoveryUpdates() throws {
        let id = UUID()
        let record = NWTXTRecord(["id": id.uuidString, "v": "1", "pv": "1.0"])
        let item = try #require(
            DiscoveredServer(
                endpoint: .service(
                    name: "Mac", type: "_kinrox._tcp", domain: "local.", interface: nil),
                record: record))
        let browser = BonjourBrowser()
        browser.update([item])
        #expect(browser.servers == [item])
        browser.update([])
        #expect(browser.servers.count == 1)
        #expect(!browser.servers[0].isAvailable)
        browser.update([item])
        #expect(browser.servers == [item])
        browser.stop()
        #expect(!browser.servers[0].isAvailable)
    }
}
