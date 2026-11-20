import CryptoKit
import Foundation

/// Deterministic per-Mac opaque identifiers for remote library entities.
/// Never leaks POSIX paths, volume UUIDs, bookmarks, or artwork cache filenames.
struct RemoteLibraryIDs: Sendable {
    static let defaultsKey = "app.kinrox.player.remoteLibraryKey"
    static let allMusic = "all-music"

    enum Kind: String, Sendable {
        case movie = "m"
        case series = "s"
        case episode = "e"
        case album = "a"
        case track = "t"
    }

    private let secret: SymmetricKey

    init(defaults: UserDefaults) {
        if let encoded = defaults.string(forKey: Self.defaultsKey),
            let data = Data(base64Encoded: encoded), data.count == 32
        {
            secret = SymmetricKey(data: data)
        } else {
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            defaults.set(data.base64EncodedString(), forKey: Self.defaultsKey)
            secret = key
        }
    }

    func id(kind: Kind, key: String) -> String {
        let input = Data((kind.rawValue + "\u{1f}" + key).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: secret)
        var hex = ""
        hex.reserveCapacity(32)
        for byte in mac.prefix(16) {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return "\(kind.rawValue)_\(hex)"
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")
}
