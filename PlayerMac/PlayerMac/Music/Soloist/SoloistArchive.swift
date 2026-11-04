import Foundation

/// Deliberately small tar subset: regular files/directories only, bounded headers and expansion.
/// Only the root Soloist executable is extracted; no archive path becomes a filesystem path.
enum SoloistArchive {
    static let maximumBytes = 64 * 1024 * 1024

    static func binary(in data: Data) throws -> Data {
        guard data.count <= maximumBytes else { throw SoloistFailure.installation }
        var offset = 0
        var paths = Set<String>()
        var binary: Range<Int>?
        var ended = false
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<offset + 512)
            if header.allSatisfy({ $0 == 0 }) {
                guard offset + 1024 <= data.count,
                    data[(offset + 512)...].allSatisfy({ $0 == 0 })
                else { throw SoloistFailure.installation }
                ended = true
                break
            }
            let path = try string(header, 0..<100)
            let prefix = try string(header, 345..<500)
            let name = prefix.isEmpty ? path : prefix + "/" + path
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
                !parts.contains(".."), !parts.contains("."), paths.insert(name).inserted,
                paths.count <= 1000, [UInt8(0), 48, 53].contains(header[156])
            else { throw SoloistFailure.installation }
            let size = try octal(header, 124..<136)
            let checksum = try octal(header, 148..<156)
            let actual = header.enumerated().reduce(0) { sum, pair in
                sum + ((148..<156).contains(pair.offset) ? 32 : Int(pair.element))
            }
            guard checksum == actual, size <= maximumBytes,
                offset + 512 + size <= data.count,
                header[156] != 53 || size == 0
            else { throw SoloistFailure.installation }
            if name == "soloist", header[156] != 53 {
                guard size > 0, binary == nil else { throw SoloistFailure.installation }
                binary = (offset + 512)..<(offset + 512 + size)
            } else if name.split(separator: "/").last == "soloist" {
                throw SoloistFailure.installation
            }
            offset += 512 + ((size + 511) / 512) * 512
        }
        guard ended, let binary else { throw SoloistFailure.installation }
        return data.subdata(in: binary)
    }

    private static func string(_ data: Data, _ range: Range<Int>) throws -> String {
        let bytes = data.subdata(in: range).prefix { $0 != 0 }
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw SoloistFailure.installation
        }
        return value
    }
    private static func octal(_ data: Data, _ range: Range<Int>) throws -> Int {
        let value = try string(data, range).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.allSatisfy({ "01234567".contains($0) }),
            let number = Int(value, radix: 8)
        else { throw SoloistFailure.installation }
        return number
    }

    static func validateMachO(_ data: Data) throws {
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { throw SoloistFailure.installation }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        guard try word(0) == 0xFEED_FACF, try word(4) == 0x0100_000C, try word(12) == 2 else {
            throw SoloistFailure.installation
        }
        let count = Int(try word(16))
        let bytes = Int(try word(20))
        guard count <= 1024, bytes <= data.count - 32 else { throw SoloistFailure.installation }
        var offset = 32
        var compatible = false
        for _ in 0..<count {
            let command = try word(offset)
            let size = Int(try word(offset + 4))
            guard size >= 8, offset + size <= 32 + bytes else { throw SoloistFailure.installation }
            if command == 0x32 {
                guard size >= 24, try word(offset + 8) == 1,
                    try word(offset + 12) <= 0x000E_0000
                else { throw SoloistFailure.installation }
                compatible = true
            }
            offset += size
        }
        guard compatible, offset == 32 + bytes else { throw SoloistFailure.installation }
    }
}
