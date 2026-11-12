import XCTest
@testable import WallpaperMachine

final class LLMLongGenerationTests: XCTestCase {
    func testDefaultsFollowConnectionAndExplicitTestLimitsStayIsolated() throws {
        var profile = LLMTestFixtures.profile()
        XCTAssertEqual(LLMStreamTransport().resolved(for: profile).limits.timeout, 1200)
        profile.localMode = true; profile.baseURL = "http://127.0.0.1:1234/v1"
        let transport = LLMStreamTransport().resolved(for: profile)
        XCTAssertEqual(transport.limits.timeout, 3600); XCTAssertEqual(transport.limits.firstContentTimeout, 600)
        XCTAssertEqual(LLMStreamTransport(limits: .init(timeout: 0.1)).resolved(for: profile).limits.timeout, 0.1)
        profile.timeoutPolicy = .init(firstResponse: 120, firstContent: 900, idle: 600, total: 7200)
        try profile.validate()
        XCTAssertEqual(LLMStreamTransport().resolved(for: profile).limits.timeout, 7200)
        profile.timeoutPolicy?.total = 7201
        XCTAssertThrowsError(try profile.validate())
    }
    func testOldProfileBytesAndCredentialBindingDoNotGainDefaultFields() throws {
        let data = try CreatorPersistence.encode(LLMTestFixtures.profile())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["timeoutPolicy"]); XCTAssertNil(object["reasoningEffort"])
        let decoded = try JSONDecoder().decode(ProviderProfile.self, from: data)
        XCTAssertEqual(try CreatorPersistence.encode(decoded), data)
    }
    func testLongThinkingAndContentSurviveFormer300SecondLimit() throws {
        var tracker = LLMDeadlineTracker(began: 0, limits: .init(timeout: 3600, firstResponseTimeout: 300, idleTimeout: 300, firstContentTimeout: 600))
        tracker.response(at: 2)
        XCTAssertNil(tracker.failure(at: 500), "Local model prefill can exceed five minutes")
        for second in stride(from: 550, through: 3500, by: 100) {
            tracker.received(bytes: 100, characters: max(0, second - 2000), effectiveContent: true, at: Double(second))
            XCTAssertNil(tracker.failure(at: Double(second + 50)))
        }
        XCTAssertEqual(tracker.failure(at: 3600)?.kind, .total)
    }
    func testHeartbeatsCannotHideMissingFirstContentAndDoKeepEstablishedStreamAlive() {
        var tracker = LLMDeadlineTracker(began: 0, limits: .init(timeout: 1200, firstResponseTimeout: 60, idleTimeout: 120, firstContentTimeout: 180))
        tracker.response(at: 1)
        for second in 2...181 { tracker.received(bytes: 8, characters: 0, effectiveContent: false, at: Double(second)) }
        XCTAssertEqual(tracker.failure(at: 181)?.kind, .firstContent)
        tracker.received(bytes: 20, characters: 0, effectiveContent: true, at: 181)
        tracker.received(bytes: 8, characters: 0, effectiveContent: false, at: 290)
        XCTAssertNil(tracker.failure(at: 400))
        XCTAssertEqual(tracker.failure(at: 410)?.kind, .idle)
    }
    func testKimiEffortDefaultsLowAndCannotLeakToUnrelatedModelOrProtocol() throws {
        var profile = LLMTestFixtures.profile()
        profile.model = "kimi-k3"
        func body(_ p: ProviderProfile) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAICompatibleCodec.request(profile: p, input: LLMTestFixtures.input, jsonMode: false).body) as? [String: Any])
        }
        XCTAssertEqual(try body(profile)["reasoning_effort"] as? String, "low")
        for effort in LLMReasoningEffort.allCases {
            profile.reasoningEffort = effort; try profile.validate()
            XCTAssertEqual(try body(profile)["reasoning_effort"] as? String, effort.rawValue)
            XCTAssertNil(try body(profile)["thinking"])
        }
        for model in ["kimi-k2.5", "qwen", "kimi-k3-unrecognized"] {
            profile.model = model
            XCTAssertNil(try body(profile)["reasoning_effort"])
            XCTAssertThrowsError(try profile.validate())
        }
        XCTAssertFalse(LLMReasoningEffort.supports("kimi-k3", protocolKind: .anthropicMessages))
    }
    func testTimeoutEvidenceRoundTripsAndDoesNotTriggerAutomaticRepair() throws {
        let evidence = LLMTimeoutEvidence(kind: .idle, elapsed: 1000, limit: 120, receivedBytes: 20000, receivedCharacters: 13000)
        let issue = CreatorRepairIssue.from(LLMFailure.deadline(evidence))
        try issue.validate(); XCTAssertFalse(issue.repairable)
        let data = try CreatorPersistence.encode(issue)
        XCTAssertEqual(try JSONDecoder().decode(CreatorRepairIssue.self, from: data), issue)
        XCTAssertEqual(issue.timeoutEvidence, evidence)
        XCTAssertFalse(CreatorRepairIssue.from(LLMFailure.truncated).repairable)
    }
    @MainActor func testThoughtClockStartsOnModelReasoningNotConnectionOrHeaders() {
        var transcript = CreatorTranscript()
        transcript.receive(.init(phase: .waiting)); XCTAssertFalse(transcript.isThinking); XCTAssertNil(transcript.thinkingStartedAt)
        transcript.receive(.init(phase: .thinking, reasoning: "Example thought")); XCTAssertTrue(transcript.isThinking)
        transcript.receive(.init(phase: .content, characters: 10, content: "<!doctype>", reasoning: "Example thought"))
        XCTAssertFalse(transcript.isThinking); XCTAssertNotNil(transcript.thinkingEndedAt)
    }
    @MainActor func testTimeoutFlushesCoalescedPartialSourceAndCancellationStillStopsImmediately() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let first = try LLMTestFixtures.frame(["choices": [["index": 0, "delta": ["content": "{\"x\":\""]]]])
        let last = try LLMTestFixtures.frame(["choices": [["index": 0, "delta": ["content": "retained-tail"]]]])
        for cancel in [false, true] {
            c.route.replace([.init(chunks: [first, last], hold: true, chunkInterval: 0.01)])
            let observed = LLMStreamingUXTests.Observations()
            let transport = LLMStreamTransport(configuration: LLMMockURLProtocol.configuration(), limits: .init(timeout: 10, firstResponseTimeout: 1, idleTimeout: cancel ? 10 : 0.15))
            let task = Task {
                try await transport.perform(URLRequest(url: c.url), decoder: OpenAICompatibleCodec(allowsLeadingThought: true), progress: { observed.add($0) }) { $0.resume() }
            }
            if cancel { try await Task.sleep(for: .milliseconds(90)); task.cancel() }
            do { _ = try await task.value; XCTFail("Held stream succeeded") } catch {
                if cancel { XCTAssertEqual(error as? LLMFailure, .cancelled) }
                else { guard case .deadline(let evidence) = error as? LLMFailure else { XCTFail("Missing timeout evidence"); return }; XCTAssertEqual(evidence.kind, .idle) }
            }
            XCTAssertEqual(observed.all.last?.content, "{\"x\":\"retained-tail")
        }
    }
}
