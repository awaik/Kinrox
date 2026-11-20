import AVFoundation
import Foundation

enum LocalAudioTagReader {
    static func read(_ url: URL, artwork: ArtworkCache) async -> LocalAudioTags {
        let title = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "flac", "ogg", "oga", "opus":
            let parsed = FLACOggTagParser.read(url)
            let raw = parsed.tags
            var tags = LocalAudioTags(title: raw["TITLE"] ?? title)
            tags.artist = raw["ARTIST"]
            tags.album = raw["ALBUM"]
            tags.albumArtist = raw["ALBUMARTIST"] ?? raw["ALBUM ARTIST"]
            tags.year = parseYear(raw["DATE"])
            tags.track = number(raw["TRACKNUMBER"])
            tags.disc = number(raw["DISCNUMBER"])
            tags.isrc = raw["ISRC"]
            tags.genres = genres(raw["GENRE"])
            tags.rating = MediaRatingScale.convert(
                raw["RATING"].flatMap(Double.init), from: 100, to: 5)
            tags.codec = parsed.codec
            tags.isLossless = parsed.codec == "FLAC"
            tags.sampleRate = parsed.sampleRate
            tags.bitDepth = parsed.bitDepth
            tags.duration = parsed.duration
            if let data = parsed.artwork { tags.artworkPath = try? await artwork.store(data) }
            return tags
        default:
            return await readAsset(url, title: title, artwork: artwork)
        }
    }

    private static func readAsset(_ url: URL, title: String, artwork: ArtworkCache) async
        -> LocalAudioTags
    {
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: false,
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            ])
        var tags = LocalAudioTags(title: title)
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0
        {
            tags.duration = duration
        }
        if let common = try? await asset.load(.commonMetadata) {
            for item in common {
                switch item.commonKey {
                case .commonKeyTitle: tags.title = await string(item) ?? tags.title
                case .commonKeyArtist: tags.artist = await string(item)
                case .commonKeyAlbumName: tags.album = await string(item)
                case .commonKeyType: tags.genres = genres(await string(item))
                case .commonKeyCreationDate:
                    tags.year = parseYear(await string(item))
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue), data.count <= 16 << 20 {
                        tags.artworkPath = try? await artwork.store(data)
                    }
                default: break
                }
            }
        }
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                let identifier = item.identifier?.rawValue ?? ""
                switch identifier {
                case "id3/TRCK", "itsk/trkn": tags.track = await metadataNumber(item)
                case "id3/TPOS", "itsk/disk": tags.disc = await metadataNumber(item)
                case "id3/TPE2", "itsk/aART": tags.albumArtist = await string(item)
                case "id3/TSRC", "itsk/ISRC": tags.isrc = await string(item)
                case "id3/TCON", "itsk/%A9gen":
                    if tags.genres.isEmpty { tags.genres = genres(await string(item)) }
                case "id3/POPM":
                    if let data = try? await item.load(.dataValue),
                        let zero = data.firstIndex(of: 0),
                        zero + 1 < data.count, data[zero + 1] > 0
                    {
                        tags.rating = MediaRatingScale.convert(
                            Double(data[zero + 1]), from: 255, to: 5)
                    }
                default: break
                }
            }
        }
        if tags.rating == nil, url.pathExtension.lowercased() == "mp3" {
            tags.rating = ID3RatingReader.rating(url)
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let format = try? await track.load(.formatDescriptions).first,
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        {
            tags.sampleRate =
                stream.mSampleRate.isFinite && (1...768_000).contains(stream.mSampleRate)
                ? Int(stream.mSampleRate) : nil
            tags.bitDepth = stream.mBitsPerChannel > 0 ? Int(stream.mBitsPerChannel) : nil
            switch stream.mFormatID {
            case kAudioFormatAppleLossless:
                tags.codec = "ALAC"
                tags.isLossless = true
                if tags.bitDepth == nil {
                    tags.bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][Int(stream.mFormatFlags)]
                }
            case kAudioFormatLinearPCM:
                tags.codec = "PCM"
                tags.isLossless = true
            case kAudioFormatMPEGLayer3: tags.codec = "MP3"
            case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
                tags.codec = "AAC"
            default: break
            }
        }
        return tags
    }

    private static func string(_ item: AVMetadataItem) async -> String? {
        guard let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseYear(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value.prefix(4)), (0...9999).contains(parsed) else {
            return nil
        }
        return parsed
    }

    private static func number(_ value: String?) -> Int? {
        guard let parsed = value?.split(separator: "/").first.flatMap({ Int($0) }), parsed >= 0
        else { return nil }
        return parsed
    }

    private static func metadataNumber(_ item: AVMetadataItem) async -> Int? {
        if let number = number(await string(item)) { return number }
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            let bytes = Array(data.prefix(4))
            return Int(bytes[2]) << 8 | Int(bytes[3])
        }
        return nil
    }

    private static func genres(_ value: String?) -> [String] {
        value?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
    }
}
