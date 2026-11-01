import Foundation

final class MusicHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = ""
        var headers: [String: String] = [:]
        var gate: MusicResponseGate?
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [Reply] = []
        private var recorded: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { recorded } }
        func reset(_ replies: [Reply]) {
            lock.withLock {
                responses = replies
                recorded = []
            }
        }
        func take(_ request: URLRequest) -> Reply {
            lock.withLock {
                recorded.append(request)
                return responses.isEmpty ? Reply(status: 500) : responses.removeFirst()
            }
        }
    }
    static let state = State()
    private var loading: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            captured.httpBody = data
        }
        let reply = Self.state.take(captured)
        loading = Task {
            await reply.gate?.wait()
            guard !Task.isCancelled else { return }
            respond(reply)
        }
    }
    private func respond(_ reply: Reply) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { loading?.cancel() }
}

actor MusicResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
