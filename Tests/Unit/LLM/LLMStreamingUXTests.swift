import XCTest
@testable import WallpaperMachine

@MainActor final class LLMStreamingUXTests: XCTestCase {
    final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LLMStreamProgress] = []
        func add(_ value: LLMStreamProgress) { lock.withLock { values.append(value) } }
        var all: [LLMStreamProgress] { lock.withLock { values } }
    }
    static func nonstream(_ text: String, reason: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "message": ["role": "assistant", "content": text, "reasoning_content": "hidden-thought"], "finish_reason": reason]],
            "usage": ["prompt_tokens": 12, "completion_tokens": 7, "total_tokens": 19]])
    }
    func testUnsupportedStreamFallsBackOnceAndConsumesBudget() async throws {
        for budget in [1, 3] {
            let c = try await LLMTestContext(requests: budget); defer { c.cleanup() }
            c.route.replace([.init(status: 400, chunks: [Data(#"{"error":{"param":"stream","message":"unsupported"}}"#.utf8)]),
                .init(headers: ["Content-Type": "application/json"], chunks: [try Self.nonstream("<think>hidden</think>{\"ok\":true}")])])
            if budget == 1 {
                do { _ = try await c.run(); XCTFail("Exceeded budget") } catch { XCTAssertEqual(error as? LLMFailure, .streamUnsupported) }
                XCTAssertEqual(c.route.requests.count, 1)
            } else {
                let completion = try await c.run()
                XCTAssertEqual(completion.response.text, #"{"ok":true}"#)
                XCTAssertEqual(completion.attempts, 2); XCTAssertEqual(completion.response.usage.totalTokens, 19)
                let bodies = try c.route.requests.map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
                XCTAssertEqual(bodies[0]["stream"] as? Bool, true); XCTAssertEqual(bodies[1]["stream"] as? Bool, false)
                XCTAssertNil(bodies[1]["stream_options"])
            }
        }
    }
    func testFirstDataIdleAndTotalDeadlinesAreIndependent() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        for (reply, limits, expected): (LLMMockURLProtocol.Reply, LLMStreamTransport.Limits, LLMTimeoutEvidence.Kind) in [
            (.init(hold: true, responseDelay: 1), .init(timeout: 2, firstResponseTimeout: 0.08, idleTimeout: 1), .firstResponse),
            (.init(chunks: [Data(": ping\n\n".utf8)], hold: true), .init(timeout: 2, firstResponseTimeout: 1, idleTimeout: 0.08), .idle),
            (.init(chunks: Array(repeating: Data(": ping\n\n".utf8), count: 20), hold: true, chunkInterval: 0.03), .init(timeout: 0.2, firstResponseTimeout: 1, idleTimeout: 0.12), .total),
            (.init(chunks: Array(repeating: Data(": ping\n\n".utf8), count: 20), hold: true, chunkInterval: 0.02), .init(timeout: 2, firstResponseTimeout: 1, idleTimeout: 0.08, firstContentTimeout: 0.15), .firstContent)
        ] {
            c.route.replace([reply])
            let transport = LLMStreamTransport(configuration: LLMMockURLProtocol.configuration(), limits: limits)
            let started = ContinuousClock.now
            do { _ = try await transport.perform(URLRequest(url: c.url), decoder: OpenAICompatibleCodec(allowsLeadingThought: true)) { $0.resume() }; XCTFail("Deadline ignored") }
            catch {
                guard case .deadline(let evidence) = error as? LLMFailure else { XCTFail("Missing deadline evidence"); continue }
                XCTAssertEqual(evidence.kind, expected); XCTAssertNoThrow(try evidence.validate())
            }
            XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        }
    }
    func testContinuousThoughtTokensKeepStreamAliveAndProgressContainsNoContent() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let thought = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"private-thought\"}}]}\n\n".utf8)
        c.route.replace([.init(chunks: [thought, thought, thought, try LLMTestFixtures.openAI(#"{"ok":true}"#)], chunkInterval: 0.05)])
        let observations = Observations()
        let transport = LLMStreamTransport(configuration: LLMMockURLProtocol.configuration(), limits: .init(timeout: 2, firstResponseTimeout: 0.1, idleTimeout: 0.15))
        let response = try await transport.perform(URLRequest(url: c.url), decoder: OpenAICompatibleCodec(allowsLeadingThought: true), progress: { observations.add($0) }) { $0.resume() }
        XCTAssertEqual(response.text, #"{"ok":true}"#)
        XCTAssertTrue(observations.all.contains { $0.phase == .thinking && $0.characters == 0 })
        XCTAssertEqual(observations.all.last?.characters, response.text.count)
        XCTAssertFalse(String(describing: observations.all).contains("private-thought"))
    }
    func testNativeProtocolsDecodeNonstreamUsageAndDiscardThoughtBlocks() throws {
        var anthropic = AnthropicMessagesCodec()
        try anthropic.consumeJSON(Data(#"{"type":"message","role":"assistant","content":[{"type":"thinking","thinking":"secret"},{"type":"text","text":"{\"ok\":true}"}],"stop_reason":"end_turn","usage":{"input_tokens":8,"output_tokens":5}}"#.utf8))
        let a = try anthropic.finish()
        XCTAssertEqual(a.text, #"{"ok":true}"#); XCTAssertEqual(a.usage.outputTokens, 5)
        var gemini = GeminiGenerateContentCodec()
        try gemini.consumeJSON(Data(#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"secret"},{"text":"{\"ok\":true}"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":5,"totalTokenCount":13}}"#.utf8))
        let g = try gemini.finish()
        XCTAssertEqual(g.text, a.text); XCTAssertEqual(g.usage.totalTokens, 13)
        let profile = LLMTestFixtures.profile(.geminiGenerateContent)
        let descriptor = try LLMRequestDescriptor.make(profile: profile, input: LLMTestFixtures.input, jsonMode: true, streaming: false)
        XCTAssertTrue(descriptor.url.path.hasSuffix(":generateContent")); XCTAssertNil(descriptor.url.query)
    }
    func testNonstreamTruncationCannotBecomeSuccessfulOutput() throws {
        var decoder = OpenAICompatibleCodec(allowsLeadingThought: true)
        XCTAssertThrowsError(try decoder.consumeJSON(Self.nonstream(#"{"ok":true}"#, reason: "length"))) { XCTAssertEqual($0 as? LLMFailure, .truncated) }
    }
}
