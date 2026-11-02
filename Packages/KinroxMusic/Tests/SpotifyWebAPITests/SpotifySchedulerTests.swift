import Foundation
import Testing

@testable import SpotifyWebAPI

extension SpotifyClientTests {
    func scheduledClient() -> SpotifyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return SpotifyClient(configuration: config) { _ in "synthetic" }
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<2000 {
            if StubURLProtocol.state.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SpotifyError.unavailable
    }
    @Test func coalescedReadsRespectRevisionAndSubscriberCancellation() async throws {
        let gate = HTTPGate()
        StubURLProtocol.state.reset([.init(body: "old", gate: gate), .init(body: "new")])
        let client = scheduledClient()
        let first = Task { try await client.request("albums/abc", query: ["b": "2", "a": "1"]) }
        try await waitForRequests(1)
        let second = Task { try await client.request("albums/abc?a=1&b=2") }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let fresh = try await SpotifyRequestContext.$revision.withValue("after-mutation") {
            try await client.request("albums/abc", query: ["a": "1", "b": "2"])
        }
        #expect(String(decoding: fresh, as: UTF8.self) == "new")
        await gate.release()
        #expect(String(decoding: try await second.value, as: UTF8.self) == "old")
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(StubURLProtocol.state.requests.count == 2)
        await client.close()
    }
    @Test func reservedControlSlotAndPriorityAdmission() async throws {
        let firstGate = HTTPGate()
        let secondGate = HTTPGate()
        StubURLProtocol.state.reset([
            .init(body: "1", gate: firstGate), .init(body: "2", gate: secondGate),
            .init(status: 204), .init(body: "interactive"), .init(body: "background"),
        ])
        let client = scheduledClient()
        let first = Task {
            try await SpotifyRequestContext.$priority.withValue(.background) {
                try await client.request("albums/first")
            }
        }
        try await waitForRequests(1)
        let second = Task {
            try await SpotifyRequestContext.$priority.withValue(.background) {
                try await client.request("albums/second")
            }
        }
        try await waitForRequests(2)
        let background = Task {
            try await SpotifyRequestContext.$priority.withValue(.background) {
                try await client.request("albums/background")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let interactive = Task { try await client.request("albums/interactive") }
        try await Task.sleep(for: .milliseconds(20))
        try await client.pause(true, deviceID: "device")
        #expect(StubURLProtocol.state.requests.count == 3)
        #expect(StubURLProtocol.state.requests[2].url?.path == "/v1/me/player/pause")
        await firstGate.release()
        _ = try await interactive.value
        #expect(StubURLProtocol.state.requests[3].url?.path == "/v1/albums/interactive")
        _ = try await background.value
        await secondGate.release()
        _ = try await first.value
        _ = try await second.value
        await client.close()
    }
    @Test func queuedRequestsRecheckShared429CooldownBeforeDispatch() async throws {
        let firstGate = HTTPGate()
        let secondGate = HTTPGate()
        StubURLProtocol.state.reset([
            .init(status: 429, headers: ["Retry-After": "60"], gate: firstGate),
            .init(body: "second", gate: secondGate),
        ])
        let client = scheduledClient()
        let first = Task { try await client.request("albums/first") }
        try await waitForRequests(1)
        let second = Task { try await client.request("albums/second") }
        try await waitForRequests(2)
        let queued = Task { try await client.request("albums/queued") }
        try await Task.sleep(for: .milliseconds(20))
        await firstGate.release()
        for task in [first, queued] {
            do {
                _ = try await task.value
                Issue.record("Expected shared cooldown")
            } catch SpotifyError.rateLimited {} catch { throw error }
        }
        #expect(StubURLProtocol.state.requests.count == 2)
        await secondGate.release()
        _ = try await second.value
        await client.close()
    }
    @Test func conditional304IsTypedAndNeverDecodesEmptyBody() async throws {
        StubURLProtocol.state.reset([.init(status: 304, headers: ["ETag": "v2"])])
        let client = scheduledClient()
        let response = try await client.resource(SpotifyAlbum.self, path: "albums/abc", etag: "v1")
        #expect(response.value == nil && response.etag == "v2")
        #expect(
            StubURLProtocol.state.requests[0].value(forHTTPHeaderField: "If-None-Match") == "v1")
        await client.close()
    }
}

extension SpotifyClientTests {
    @Test func multipageResourceDoesNotKeepFirstPageValidator() async throws {
        StubURLProtocol.state.reset([
            .init(
                body: #"{"items":[1],"next":"https://api.spotify.com/v1/example?offset=1"}"#,
                headers: ["ETag": "first"]),
            .init(body: #"{"items":[2],"next":null}"#),
        ])
        let client = scheduledClient()
        let result = try await client.resourcePages(Int.self, path: "example")
        #expect(result.value == [1, 2])
        #expect(result.etag == nil)
        await client.close()
    }

    @Test(arguments: [false, true]) func cancelledRequestReleasesSlotBeforeResponse(live: Bool)
        async throws
    {
        let gate = HTTPGate()
        StubURLProtocol.state.reset([.init(body: "held", gate: gate)])
        let client = scheduledClient()
        actor Completion {
            var finished = false
            func finish() { finished = true }
        }
        let completion = Completion()
        let task = Task {
            do { _ = try await client.request("albums/cancel", live: live) } catch {}
            await completion.finish()
        }
        try await waitForRequests(1)
        task.cancel()
        for _ in 0..<100 {
            if await completion.finished { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await completion.finished)
        await gate.release()
        await task.value
        await client.close()
    }
}

extension SpotifyClientTests {
    @Test func cancellingLastReadersFreesAdmissionForNewRequests() async throws {
        let gate = HTTPGate()
        StubURLProtocol.state.reset([
            .init(body: "first", gate: gate), .init(body: "second", gate: gate),
            .init(body: "interactive"),
        ])
        let client = scheduledClient()
        let first = Task { try await client.request("albums/first") }
        try await waitForRequests(1)
        let second = Task { try await client.request("albums/second") }
        try await waitForRequests(2)
        let cancelled = Task { try await client.request("albums/queued") }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let next = Task { try await client.request("albums/interactive") }
        do { try await waitForRequests(3) } catch {
            Issue.record("Cancellation did not release scheduler admission")
        }
        // Release even on failure so a regression cannot hang the suite.
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(String(decoding: try await next.value, as: UTF8.self) == "interactive")
        _ = try await second.value
        #expect(!StubURLProtocol.state.requests.contains { $0.url?.path == "/v1/albums/queued" })
        await client.close()
    }
}

extension SpotifyClientTests {
    @Test func cancelledSubscriberReturnsWhileOtherSubscriberStillWaits() async throws {
        let gate = HTTPGate()
        StubURLProtocol.state.reset([.init(body: "shared", gate: gate)])
        let client = scheduledClient()
        actor Completion {
            var cancelled = false
            func finish() { cancelled = true }
        }
        let completion = Completion()
        let first = Task {
            do {
                _ = try await client.request("albums/shared")
                Issue.record("Cancelled subscriber received a response")
            } catch is CancellationError {
                await completion.finish()
            } catch { Issue.record(error) }
        }
        try await waitForRequests(1)
        let second = Task { try await client.request("albums/shared") }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        for _ in 0..<100 {
            if await completion.cancelled { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await completion.cancelled)
        await gate.release()
        await first.value
        #expect(String(decoding: try await second.value, as: UTF8.self) == "shared")
        #expect(StubURLProtocol.state.requests.count == 1)
        await client.close()
    }
}
