import Foundation
import Testing

@MainActor
struct SpotifySpikeQuotaTests {
    @Test func quotaExceededPreservesRetryAfterAndDoesNotHammerService() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaResponseProtocol.self]
        let api = SpotifySpikeAPI(token: "test-only", session: URLSession(configuration: config))
        defer { api.close() }
        do {
            _ = try await api.request("me/library?uris=spotify:track:test", method: "DELETE")
            Issue.record("Expected the simulated quota error")
        } catch SpotifySpikeFailure.http(let status, let retryAfter, let quotaExceeded) {
            #expect(status == 429)
            #expect(retryAfter == "7")
            #expect(quotaExceeded)
        }
        #expect(api.requestCount == 1)
    }
}

private final class QuotaResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "7"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self, didLoad: Data(#"{"error":{"status":429,"message":"QUOTA_EXCEEDED"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
