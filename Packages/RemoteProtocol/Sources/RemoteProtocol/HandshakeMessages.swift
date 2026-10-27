import Foundation

extension Message {
    // Binary fields are strictly canonical Base64; codec verifies 32-byte length.
    public struct Hello: Codable, Sendable, Equatable {
        public let minVersion: Int
        public let maxVersion: Int
        public let deviceId: UUID
        public let deviceName: String
        public let appVersion: String

        public init(
            minVersion: Int, maxVersion: Int, deviceId: UUID, deviceName: String, appVersion: String
        ) {
            self.minVersion = minVersion
            self.maxVersion = maxVersion
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.appVersion = appVersion
        }
    }

    public struct HelloAck: Codable, Sendable, Equatable {
        public let version: Int
        public let serverId: UUID
        public let serverName: String
        public let needsPairing: Bool
        public let serverPublicKey: Data
        public let nonce: Data

        public init(
            version: Int, serverId: UUID, serverName: String, needsPairing: Bool,
            serverPublicKey: Data, nonce: Data
        ) {
            self.version = version
            self.serverId = serverId
            self.serverName = serverName
            self.needsPairing = needsPairing
            self.serverPublicKey = serverPublicKey
            self.nonce = nonce
        }
    }

    public struct PairRequest: Codable, Sendable, Equatable {
        public let clientPublicKey: Data

        public init(clientPublicKey: Data) { self.clientPublicKey = clientPublicKey }
    }

    public struct PairProof: Codable, Sendable, Equatable {
        public let proof: Data

        public init(proof: Data) { self.proof = proof }
    }

    public struct Auth: Codable, Sendable, Equatable {
        public let deviceId: UUID
        public let clientPublicKey: Data
        public let proof: Data

        public init(deviceId: UUID, clientPublicKey: Data, proof: Data) {
            self.deviceId = deviceId
            self.clientPublicKey = clientPublicKey
            self.proof = proof
        }
    }

    /// Codec returns JSON; `paired` can only be transmitted inside an encrypted channel.
    public struct Paired: Codable, Sendable, Equatable {
        public let token: Data

        public let serverProof: Data

        public init(token: Data, serverProof: Data) {
            self.token = token
            self.serverProof = serverProof
        }
    }

    public struct AuthOk: Codable, Sendable, Equatable {
        public let serverProof: Data

        public init(serverProof: Data) { self.serverProof = serverProof }
    }

    public struct Acknowledgement: Codable, Sendable, Equatable {
        public let replyTo: UUID

        public init(replyTo: UUID) { self.replyTo = replyTo }
    }
}
