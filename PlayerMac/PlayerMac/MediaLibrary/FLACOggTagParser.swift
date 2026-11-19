import Foundation

enum FLACOggTagParser {
    struct Result {
        var tags: [String: String] = [:]
        var artwork: Data?
        var sampleRate: Int?
        var bitDepth: Int?
        var duration: Double?
        var codec: String?
    }

    private static let commentLimit = 1 << 20
    private static let pictureLimit = 16 << 20

    static func read(_ url: URL) -> Result {
        guard let file = try? FileHandle(forReadingFrom: url) else { return Result() }
        defer { try? file.close() }
        do {
            let signature = try file.read(upToCount: 4)
            try file.seek(toOffset: 0)
            if signature == Data("fLaC".utf8) { return try flac(file) }
            if signature == Data("OggS".utf8) { return try ogg(file) }
        } catch {}
        return Result()
    }

    private static func flac(_ file: FileHandle) throws -> Result {
        try file.seek(toOffset: 4)
        var result = Result(codec: "FLAC")
        for _ in 0..<256 {
            guard let header = try file.read(upToCount: 4), header.count == 4 else { break }
            let type = header[0] & 127
            let size = Int(header.number(at: 1, width: 3) ?? 0)
            let limit =
                switch type {
                case 0: 34
                case 4: commentLimit
                case 6: pictureLimit
                default: 0
                }
            if size > 0, size <= limit, let data = try file.read(upToCount: size),
                data.count == size
            {
                switch type {
                case 0:
                    if let packed = data.number(at: 10, width: 8) {
                        let rate = Int(packed >> 44)
                        result.sampleRate = rate > 0 ? rate : nil
                        result.bitDepth = Int((packed >> 36) & 31) + 1
                        let samples = packed & 0xF_FFFF_FFFF
                        if rate > 0, samples > 0 {
                            result.duration = Double(samples) / Double(rate)
                        }
                    }
                case 4: result.tags = comments(data, offset: 0)
                case 6:
                    if result.artwork == nil, let picture = picture(data), picture.type == 3 {
                        result.artwork = picture.data
                    } else if result.artwork == nil {
                        result.artwork = picture(data)?.data
                    }
                default: break
                }
            } else {
                try file.seek(toOffset: file.offset() + UInt64(size))
            }
            if header[0] & 128 != 0 { break }
        }
        return result
    }

    private static func ogg(_ file: FileHandle) throws -> Result {
        var result = Result()
        var stream: UInt64?
        var packet = Data()
        var packetCount = 0
        var preSkip: UInt64 = 0
        pages: for _ in 0..<64 {
            guard let header = try file.read(upToCount: 27), header.count == 27,
                header.prefix(4) == Data("OggS".utf8), header[4] == 0,
                let serial = header.number(at: 14, width: 4, littleEndian: true),
                let lacing = try file.read(upToCount: Int(header[26])),
                lacing.count == Int(header[26])
            else { break }
            let length = lacing.reduce(0) { $0 + Int($1) }
            let body = try file.read(upToCount: length) ?? Data()
            guard body.count == length else { break }
            if stream == nil { stream = serial }
            guard stream == serial else { continue }
            var offset = 0
            for size in lacing {
                let end = offset + Int(size)
                guard packet.count + Int(size) <= commentLimit else { break pages }
                packet.append(body[offset..<end])
                offset = end
                if size == 255 { continue }
                packetCount += 1
                if packetCount == 1 {
                    if packet.starts(with: "OpusHead".utf8) {
                        result.codec = "Opus"
                        result.sampleRate = 48_000
                        preSkip = packet.number(at: 10, width: 2, littleEndian: true) ?? 0
                    } else if packet.starts(with: [1] + Array("vorbis".utf8)) {
                        result.codec = "Vorbis"
                        result.sampleRate = packet.number(at: 12, width: 4, littleEndian: true).map(
                            Int.init)
                    } else {
                        break pages
                    }
                } else {
                    if packet.starts(with: "OpusTags".utf8) {
                        result.tags = comments(packet, offset: 8)
                    }
                    if packet.starts(with: [3] + Array("vorbis".utf8)) {
                        result.tags = comments(packet, offset: 7)
                    }
                    break pages
                }
                packet.removeAll(keepingCapacity: true)
            }
        }

        if let encoded = result.tags.removeValue(forKey: "METADATA_BLOCK_PICTURE"),
            let data = Data(base64Encoded: encoded)
        {
            result.artwork = picture(data)?.data
        }
        if let stream, let sampleRate = result.sampleRate, sampleRate > 0,
            let granule = try lastGranule(file, stream: stream), granule > preSkip
        {
            result.duration = Double(granule - preSkip) / Double(sampleRate)
        }
        return result
    }

    private static func lastGranule(_ file: FileHandle, stream: UInt64) throws -> UInt64? {
        let end = try file.seekToEnd()
        let count = Int(min(65_536, end))
        try file.seek(toOffset: end - UInt64(count))
        guard let tail = try file.read(upToCount: count), tail.count >= 27 else { return nil }
        for start in stride(from: tail.count - 27, through: 0, by: -1) {
            guard tail[start..<(start + 4)].elementsEqual("OggS".utf8), tail[start + 4] == 0,
                tail.number(at: start + 14, width: 4, littleEndian: true) == stream,
                let granule = tail.number(at: start + 6, width: 8, littleEndian: true),
                granule <= UInt64(Int64.max)
            else { continue }
            let headerEnd = start + 27 + Int(tail[start + 26])
            guard headerEnd <= tail.count else { continue }
            let bodyLength = tail[(start + 27)..<headerEnd].reduce(0) { $0 + Int($1) }
            if headerEnd + bodyLength <= tail.count { return granule }
        }
        return nil
    }

    private static func comments(_ data: Data, offset: Int) -> [String: String] {
        var cursor = offset
        guard blob(data, cursor: &cursor, littleEndian: true) != nil,
            let count = data.number(at: cursor, width: 4, littleEndian: true), count <= 10_000
        else { return [:] }
        cursor += 4
        var tags: [String: String] = [:]
        for _ in 0..<count {
            guard let field = blob(data, cursor: &cursor, littleEndian: true) else { break }
            guard let string = String(data: field, encoding: .utf8),
                let separator = string.firstIndex(of: "=")
            else { continue }
            let key = string[..<separator].uppercased()
            let value = String(string[string.index(after: separator)...])
            if key == "GENRE", let existing = tags[key] {
                tags[key] = existing + ";" + value
            } else if tags[key] == nil {
                tags[key] = value
            }
        }
        return tags
    }

    private static func picture(_ data: Data) -> (type: UInt64, data: Data)? {
        guard data.count <= pictureLimit, let type = data.number(at: 0, width: 4) else {
            return nil
        }
        var cursor = 4
        guard let mime = blob(data, cursor: &cursor), mime != Data("-->".utf8),
            blob(data, cursor: &cursor) != nil
        else { return nil }
        cursor += 16
        guard let image = blob(data, cursor: &cursor), !image.isEmpty else { return nil }
        return (type, image)
    }

    private static func blob(_ data: Data, cursor: inout Int, littleEndian: Bool = false) -> Data? {
        guard let length = data.number(at: cursor, width: 4, littleEndian: littleEndian),
            Int(length) <= data.count - cursor - 4
        else { return nil }
        let start = cursor + 4
        cursor = start + Int(length)
        return data.subdata(in: start..<cursor)
    }
}

extension Data {
    fileprivate func number(at index: Int, width: Int, littleEndian: Bool = false) -> UInt64? {
        guard index >= 0, index <= count - width else { return nil }
        let bytes = self[index..<(index + width)]
        if littleEndian { return bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) } }
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
