import Foundation

/// AVFoundation does not expose POPM consistently. Read only the bounded ID3 header.
enum ID3RatingReader {
    static func rating(_ url: URL) -> Double? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 10), header.count == 10,
            header.starts(with: "ID3".utf8), header[3] == 3 || header[3] == 4,
            let tagSize = syncSafe(header[6..<10]), tagSize <= 1 << 20,
            let tag = try? file.read(upToCount: tagSize), tag.count == tagSize
        else { return nil }
        let version = header[3]
        var cursor = 0
        if header[5] & 0x40 != 0 {
            guard tag.count >= 4 else { return nil }
            if version == 4 {
                guard let size = syncSafe(tag[0..<4]), size >= 4 else { return nil }
                cursor = size
            } else {
                cursor = 4 + bigEndian(tag[0..<4])
            }
        }
        while cursor <= tag.count - 10 {
            let end = cursor + 10
            let name = tag[cursor..<(cursor + 4)]
            if name.first == 0 { return nil }
            let sizeBytes = tag[(cursor + 4)..<(cursor + 8)]
            let size = version == 4 ? syncSafe(sizeBytes) : bigEndian(sizeBytes)
            guard let size, size > 0, size <= tag.count - end else { return nil }
            if name.elementsEqual("POPM".utf8), tag[cursor + 9] == 0 {
                let frame = tag[end..<(end + size)]
                if let terminator = frame.firstIndex(of: 0), terminator + 1 < frame.endIndex {
                    let value = frame[terminator + 1]
                    if value > 0 {
                        return MediaRatingScale.convert(Double(value), from: 255, to: 5)
                    }
                }
            }
            cursor = end + size
        }
        return nil
    }

    private static func syncSafe(_ field: Data) -> Int? {
        guard field.allSatisfy({ $0 < 128 }) else { return nil }
        return field.reduce(0) { $0 << 7 | Int($1) }
    }

    private static func bigEndian(_ field: Data) -> Int {
        field.reduce(0) { $0 << 8 | Int($1) }
    }
}
