import XCTest
@testable import WallpaperMachine

@MainActor final class LLMThoughtStreamTests: XCTestCase {
    func testLeadingTagsSplitAtEveryCharacterSeparateThinkingFromLiteralHTML() throws {
        let html = "<!DOCTYPE html><html><body><script>const t='<think>literal</think>';</script></body></html>"
        var buffer = LLMAnswerBuffer(allowsLeadingThought: true, requiresJSON: false)
        for character in "<think>先思考🌙\nsecond line</think>" + html { try buffer.append(String(character)) }
        XCTAssertEqual(buffer.reasoning, "先思考🌙\nsecond line")
        XCTAssertEqual(buffer.content, html)
        XCTAssertEqual(try buffer.finish(usage: .init()).text, html)
        XCTAssertFalse(buffer.reasoningTruncated)
    }
    func testThreeProtocolThinkingChannelsAreObservableButNeverPartOfAnswerOrDescriptions() throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            var decoder = LLMRequestDescriptor.decoder(for: LLMTestFixtures.profile(kind))
            var parser = SSEParser()
            for event in try parser.append(LLMTestFixtures.body(for: kind)) { try decoder.consume(event) }
            XCTAssertTrue(decoder.progress.reasoning.contains("private"))
            XCTAssertFalse(try decoder.finish().text.contains("private"))
            XCTAssertFalse(String(describing: decoder.progress).contains("private"))
            XCTAssertFalse(String(reflecting: decoder.progress).contains("private"))
            XCTAssertTrue(Mirror(reflecting: decoder.progress).children.isEmpty)
        }
    }
    func testDisplayRedactsCompleteKeysAndEveryPartialKeySuffixWithoutDamagingNewlines() throws {
        let secret = "fixture-secret-123"
        let grant = ProviderCredentialStore.Grant(profile: LLMTestFixtures.profile(), key: secret)
        for count in 1...secret.count {
            let partial = String(secret.prefix(count))
            let update = grant.redactingProgress(.init(content: "<html>\n" + partial, reasoning: "thinking\n" + partial))
            XCTAssertFalse(update.content.hasSuffix(partial))
            XCTAssertFalse(update.reasoning.hasSuffix(partial))
            XCTAssertTrue(update.content.contains("\n"))
        }
        let update = grant.redactingProgress(.init(content: "<html>" + secret + "</html>", reasoning: "key " + secret + " /Users/fixture/private https://fixture.invalid"))
        XCTAssertFalse(update.content.contains(secret)); XCTAssertFalse(update.reasoning.contains("/Users/"))
        XCTAssertFalse(update.reasoning.contains("https://"))
    }
    func testReasoningDisplayIsBoundedWithoutTruncatingTheExecutableAnswer() throws {
        var buffer = LLMAnswerBuffer(allowsLeadingThought: true)
        buffer.appendReasoning(String(repeating: "🌙", count: LLMAnswerBuffer.maximumReasoningBytes))
        XCTAssertLessThanOrEqual(buffer.reasoning.utf8.count, LLMAnswerBuffer.maximumReasoningBytes)
        XCTAssertTrue(buffer.reasoningTruncated)
        try buffer.append(#"{"ok":true}"#)
        XCTAssertEqual(try buffer.finish(usage: .init()).text, #"{"ok":true}"#)
    }
    func testTruncatedResponseStillDisplaysTheReceivedContentAndReportedUsage() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let frame = try LLMTestFixtures.frame(["choices": [["index": 0, "delta": ["content": "{", "reasoning_content": "plan"], "finish_reason": "length"]],
            "usage": ["prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20]])
        c.route.replace([.init(chunks: [frame])])
        let observed = CreatorStreamMailbox()
        do {
            _ = try await c.provider.generate(LLMTestFixtures.input, profileID: c.profile.id, configurationID: c.profile.configurationID,
                ticket: c.ticket, store: c.store, progress: { observed.store($0) })
            XCTFail("Truncated output accepted")
        } catch { XCTAssertEqual(error as? LLMFailure, .truncated) }
        XCTAssertEqual(observed.latest.content, "{"); XCTAssertEqual(observed.latest.reasoning, "plan")
        XCTAssertEqual(observed.latest.usage.totalTokens, 20)
        XCTAssertEqual(c.route.requests.count, 1)
    }
    func testProviderDeliversRedactedContentAndUsageWithNoTranscriptInDiskOrLogs() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let frames = try LLMTestFixtures.frame(["choices": [["index": 0, "delta": ["reasoning_content": LLMTestFixtures.key + "\nplan"]]]])
            + LLMTestFixtures.openAI(#"{"ok":true}"#)
        c.route.replace([.init(chunks: [frames])])
        let observed = CreatorStreamMailbox()
        _ = try await c.provider.generate(LLMTestFixtures.input, profileID: c.profile.id, configurationID: c.profile.configurationID,
            ticket: c.ticket, store: c.store, progress: { observed.store($0) })
        XCTAssertTrue(observed.latest.reasoning.contains("plan"))
        XCTAssertFalse(observed.latest.reasoning.contains(LLMTestFixtures.key))
        XCTAssertEqual(observed.latest.content, #"{"ok":true}"#)
        XCTAssertEqual(observed.latest.usage.totalTokens, 20)
        XCTAssertFalse(c.diagnostics.lines.joined().contains("plan"))
        let job = try await c.store.generatingJob(c.ticket)
        XCTAssertFalse(String(decoding: try CreatorPersistence.record(job), as: UTF8.self).contains("plan"))
    }
}
