import XCTest
@testable import WallpaperMachine

@MainActor
final class LLMStreamTransportTests: XCTestCase {
    func testRetryAfterSupportsDeltaAndHTTPDateAndRejectsInvalidValues() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(LLMHTTPPolicy.retryAfter("12", now: now), 12)
        XCTAssertEqual(LLMHTTPPolicy.retryAfter("Thu, 01 Jan 1970 00:00:05 GMT", now: now), 5)
        XCTAssertEqual(LLMHTTPPolicy.retryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now: Date(timeIntervalSince1970: 5)), 0)
        for value in ["-1", "NaN", "inf", "one", String(repeating: "1", count: 129)] {
            XCTAssertNil(LLMHTTPPolicy.retryAfter(value, now: now))
        }
    }
    func testPreparedRequestIsRecheckedAfterCredentialsWereReadAndBeforeResume() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let grant = try await c.credentials.resolve(for: c.profile, settings: c.settings)
        let request = try grant.request(LLMRequestDescriptor.make(profile: c.profile, input: LLMTestFixtures.input, jsonMode: true))
        var changed = c.profile; changed.baseURL = "https://new.invalid"
        let settings = try await c.settings.settings()
        _ = try await c.settings.saveProfile(changed, expectedRevision: settings.revision)
        let store = c.settings, profile = c.profile
        let transport = LLMStreamTransport(configuration: LLMMockURLProtocol.configuration())
        do {
            _ = try await transport.perform(request, decoder: LLMRequestDescriptor.decoder(for: profile)) { task in
                try await store.withCurrentProfile(profile) { _ in task.resume() }
            }
            XCTFail("Resumed a request with stale credentials")
        } catch { XCTAssertEqual(error as? LLMFailure, .staleProfile) }
        XCTAssertTrue(c.route.requests.isEmpty)
    }
    func testCrossOriginRedirectNeverReachesDestination() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let destination = URL(string: "https://redirected.invalid/v1/chat/completions")!
        let target = LLMMockURLProtocol.Route([.init(chunks: [try LLMTestFixtures.openAI()])])
        LLMMockURLProtocol.register(target, at: destination); defer { LLMMockURLProtocol.remove(destination) }
        c.route.replace([.init(redirect: destination)])
        do { _ = try await c.run(); XCTFail("Followed a cross-origin redirect") }
        catch { XCTAssertEqual(error as? LLMFailure, .redirectRejected) }
        XCTAssertEqual(c.route.requests.count, 1)
        XCTAssertTrue(target.requests.isEmpty)
    }
    func testRedirectDelegateLatchesFailureBeforeAReentrantResponseAndRejectsSameOriginToo() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let session = URLSession(configuration: LLMMockURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        for destination in [c.url, URL(string: "https://other.invalid")!, URL(string: "http://fixture.invalid")!] {
            let request = URLRequest(url: c.url)
            let operation = LLMStreamOperation(request: request, decoder: LLMRequestDescriptor.decoder(for: c.profile),
                configuration: LLMMockURLProtocol.configuration(), limits: .init())
            let task = session.dataTask(with: request) // Never resumed.
            let response = HTTPURLResponse(url: c.url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: [:])!
            operation.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: destination)) { forwarded in
                XCTAssertNil(forwarded)
                operation.urlSession(session, dataTask: task, didReceive: response) { disposition in XCTAssertEqual(disposition, .cancel) }
                operation.urlSession(session, task: task, didCompleteWithError: nil)
            }
            do { _ = try await operation.run { _ in XCTFail("Started a rejected redirect") }; XCTFail("Lost redirect failure") }
            catch { XCTAssertEqual(error as? LLMFailure, .redirectRejected) }
        }
        XCTAssertTrue(c.route.requests.isEmpty)
    }
    func testStreamAndOutputBoundsRejectEvenDiscardedThoughtData() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let grant = try await c.credentials.resolve(for: c.profile, settings: c.settings)
        let request = try grant.request(LLMRequestDescriptor.make(profile: c.profile, input: LLMTestFixtures.input, jsonMode: true))
        c.route.replace([.init(chunks: [Data(": ignored heartbeat with hidden data\n\n".utf8)])])
        let transport = LLMStreamTransport(configuration: LLMMockURLProtocol.configuration(), limits: .init(maximumBytes: 10))
        do { _ = try await transport.perform(request, decoder: LLMRequestDescriptor.decoder(for: c.profile)) { $0.resume() }; XCTFail("Accepted oversized stream") }
        catch { XCTAssertEqual(error as? LLMFailure, .streamLimit) }
    }
    func testCancellationBeforeResumeSurvivesLateValidDelegateCallbacks() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let operation = LLMStreamOperation(request: URLRequest(url: c.url), decoder: LLMRequestDescriptor.decoder(for: c.profile),
            configuration: LLMMockURLProtocol.configuration(), limits: .init())
        let running = Task {
            try await operation.run { _ in
                // Hold the suspended task. Cancellation must finish without waiting for this hook.
                try await Task.sleep(for: .seconds(10))
            }
        }
        running.cancel()
        do { _ = try await running.value; XCTFail("Ignored cancellation before resume") }
        catch { XCTAssertEqual(error as? LLMFailure, .cancelled) }
        let session = URLSession(configuration: LLMMockURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let dummy = session.dataTask(with: c.url)
        let response = HTTPURLResponse(url: c.url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        operation.urlSession(session, dataTask: dummy, didReceive: response) { XCTAssertEqual($0, .cancel) }
        operation.urlSession(session, dataTask: dummy, didReceive: try LLMTestFixtures.openAI())
        operation.urlSession(session, task: dummy, didCompleteWithError: nil)
        do { _ = try await operation.run { _ in XCTFail("Restarted a cancelled stream") }; XCTFail("Overwrote cancellation with late success") }
        catch { XCTAssertEqual(error as? LLMFailure, .cancelled) }
        XCTAssertTrue(c.route.requests.isEmpty)
    }
    func testInvalidContentTypeAndTruncatedFinalSSEFrameCannotPassAfterDone() async throws {
        for invalidType in [false, true] {
            let c = try await LLMTestContext(); defer { c.cleanup() }
            var body = try LLMTestFixtures.openAI()
            if !invalidType { body.append(Data("data: tail".utf8)) }
            c.route.replace([.init(headers: ["Content-Type": invalidType ? "application/json" : "text/event-stream"], chunks: [body])])
            do { _ = try await c.run(); XCTFail("Accepted invalid stream completion") }
            catch { XCTAssertEqual(error as? LLMFailure, invalidType ? .protocolViolation : .truncated) }
        }
    }
}
