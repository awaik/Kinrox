import CryptoKit
import Foundation

struct HandshakeKeys {
    let transcript: HandshakeTranscript
    let clientToServer: SymmetricKey
    let serverToClient: SymmetricKey
    let confirmation: SymmetricKey

    init(
        transcript: HandshakeTranscript, privateKey: Curve25519.KeyAgreement.PrivateKey,
        role: SecureChannel.Role
    ) throws {
        let peer =
            role == .client
            ? transcript.acknowledgement.serverPublicKey : transcript.clientPublicKey
        let own =
            role == .client
            ? transcript.clientPublicKey : transcript.acknowledgement.serverPublicKey
        guard privateKey.publicKey.rawRepresentation == own else {
            throw SessionFailure(.authFailed)
        }
        let secret: SharedSecret
        do {
            secret = try privateKey.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        } catch { throw SessionFailure(.authFailed) }
        let nonzero = secret.withUnsafeBytes { $0.reduce(UInt8(0)) { $0 | $1 } }
        guard nonzero != 0 else { throw SessionFailure(.authFailed) }
        func derive(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcript.acknowledgement.nonce,
                sharedInfo: CryptoBytes.label(label) + transcript.hash, outputByteCount: 32)
        }
        self.transcript = transcript
        clientToServer = derive("key/c2s")
        serverToClient = derive("key/s2c")
        confirmation = derive("key/confirm")
    }

    func pinKey(_ pin: String) throws -> SymmetricKey {
        let bytes = Data(pin.utf8)
        guard bytes.count == 6, bytes.allSatisfy({ (48...57).contains($0) }) else {
            throw SessionFailure(.invalidPayload)
        }
        return deriveSecret(bytes, label: "pin")
    }

    func authServerKey(_ token: Data) throws -> SymmetricKey {
        guard token.count == 32 else { throw SessionFailure(.invalidPayload) }
        return deriveSecret(token, label: "auth/server-key")
    }

    private func deriveSecret(_ bytes: Data, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            salt: confirmation.withUnsafeBytes { Data($0) },
            info: CryptoBytes.label(label) + transcript.hash, outputByteCount: 32)
    }

    func pairClientInput(_ id: UUID) -> Data {
        CryptoBytes.label("pair/client") + transcript.bytes + CryptoBytes.uuid(id)
    }

    func pairServerInput(_ id: UUID, proof: Data, token: Data) -> Data {
        CryptoBytes.label("pair/server") + transcript.bytes + CryptoBytes.uuid(id) + proof + token
    }

    var authClientInput: Data { CryptoBytes.label("auth/client") + transcript.bytes }

    func authServerInput(_ proof: Data) -> Data {
        CryptoBytes.label("auth/server") + transcript.bytes + proof
    }

    static func mac(_ input: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
    }

    static func verify(_ proof: Data, input: Data, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: input, using: key)
    }
}
