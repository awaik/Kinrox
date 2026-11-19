import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ArtworkCache {
    private let directory: URL
    private let session: URLSession
    private let thumbnails = NSCache<NSString, NSData>()
    private let maximumBytes = 10 << 20

    init(directory: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.directory = directory
        session = URLSession(
            configuration: LibraryHTTP.configuration(configuration),
            delegate: ArtworkRedirects(), delegateQueue: nil)
        thumbnails.countLimit = 100
        thumbnails.totalCostLimit = 12 << 20
    }

    func fetch(_ url: URL) async throws -> String? {
        guard Self.allows(url) else { return nil }
        try Task.checkCancellation()
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.expectedContentLength <= maximumBytes, data.count <= maximumBytes,
            let finalURL = response.url, Self.allows(finalURL)
        else { return nil }
        try Task.checkCancellation()
        return try store(data)
    }

    func store(_ data: Data) throws -> String? {
        try Task.checkCancellation()
        guard data.count <= 16 << 20 else { return nil }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".jpg"
        let url = directory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: url.path) { return key }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                ] as CFDictionary)
        else { return nil }
        let jpeg = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                jpeg, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.85
            ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (jpeg as Data).write(to: url, options: .atomic)
        return key
    }

    func thumbnail(_ key: String) -> Data? {
        guard key.wholeMatch(of: /[a-f0-9]{64}\.jpg/) != nil else { return nil }
        if let cached = thumbnails.object(forKey: key as NSString) { return cached as Data }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key)) else {
            return nil
        }
        thumbnails.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
            url.port == nil || url.port == 443, let host = url.host?.lowercased()
        else { return false }
        return [
            "coverartarchive.org", "archive.org", "images.metahub.space", "static.tvmaze.com",
            "m.media-amazon.com",
        ].contains(host) || host.hasSuffix(".archive.org")
    }
}

private final class ArtworkRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let origin = response.url, ArtworkCache.allows(origin),
            let url = request.url, ArtworkCache.allows(url), request.httpMethod == "GET"
        else {
            completionHandler(nil)
            return
        }
        var clean = URLRequest(url: url)
        clean.httpShouldHandleCookies = false
        completionHandler(clean)
    }
}

enum LibraryHTTP {
    static func configuration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.httpAdditionalHeaders = [
            "User-Agent":
                "Kinrox/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development") ( https://kinrox.app )"
        ]
        return config
    }
}
