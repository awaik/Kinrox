import Foundation
import Network

/// Advertisement belongs to NWListener: its cancellation also withdraws the Bonjour service.
public struct BonjourAdvertiser: Sendable {
    public let serverId: UUID
    public let name: String
    public let appVersion: String

    public init(serverId: UUID, name: String, appVersion: String) throws {
        guard (1...63).contains(name.utf8.count), (1...252).contains(appVersion.utf8.count),
            !name.contains("\0"), !appVersion.contains("\0")
        else { throw TransportFailure.invalidService }
        self.serverId = serverId
        self.name = name
        self.appVersion = appVersion
    }

    var service: NWListener.Service {
        NWListener.Service(
            name: name, type: TransportConfiguration.serviceType,
            domain: TransportConfiguration.domain,
            txtRecord: NWTXTRecord([
                "v": String(TransportConfiguration.protocolVersion),
                "id": serverId.uuidString, "pv": appVersion,
            ]))
    }
}

public struct DiscoveredServer: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let appVersion: String
    public let protocolVersion: Int
    public let endpoint: NWEndpoint
    public internal(set) var isAvailable: Bool

    init?(endpoint: NWEndpoint, record: NWTXTRecord) {
        guard case .service(let name, let type, let domain, _) = endpoint,
            type == TransportConfiguration.serviceType,
            domain.lowercased() == TransportConfiguration.domain,
            let rawId = record["id"], let id = UUID(uuidString: rawId),
            let rawVersion = record["v"], let version = UInt32(rawVersion), version > 0,
            let appVersion = record["pv"], !appVersion.isEmpty
        else { return nil }
        self.id = id
        self.name = name
        self.appVersion = appVersion
        protocolVersion = Int(version)
        self.endpoint = endpoint
        isAvailable = true
    }
}
