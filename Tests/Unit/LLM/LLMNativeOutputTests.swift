import XCTest
@testable import WallpaperMachine

@MainActor final class LLMNativeOutputTests: XCTestCase {
    func testProfileNativeAndExplicitLimitsPreserveLegacyEncoding() throws {
        let native = ProviderProfile.Limits()
        XCTAssertEqual(native.nativeOutputLimit, true)
        XCTAssertEqual(native.outputTokensPerRequest, 131_072)
        XCTAssertEqual(native.generationTokenBudget, 393_216)
        let explicit = ProviderProfile.Limits(requestBudget: 3, tokenBudget: 131_072, nativeOutputLimit: false)
        XCTAssertEqual(explicit.outputTokensPerRequest, 131_072)
        let legacy = Data(#"{"requestBudget":3,"tokenBudget":12000}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderProfile.Limits.self, from: legacy)
        XCTAssertNil(decoded.nativeOutputLimit); XCTAssertEqual(decoded.outputTokensPerRequest, 4000)
        XCTAssertEqual(try CreatorPersistence.encode(decoded), legacy)
        for kind in ProviderProfile.ProtocolKind.allCases {
            var profile = LLMTestFixtures.profile(kind); profile.limits = .init()
            var input = LLMTestFixtures.input; input.maxOutputTokens = 131_072; input.nativeOutputLimit = true
            let body = try JSONSerialization.jsonObject(with: LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false).body) as! [String: Any]
            if kind == .anthropicMessages { XCTAssertEqual(body["max_tokens"] as? Int, 131_072) }
            else { XCTAssertNil(body["max_tokens"]); XCTAssertNil((body["generationConfig"] as? [String: Any])?["maxOutputTokens"]) }
        }
    }
    func testContextAndUsageFallbackCountAttemptsAndRetainStreaming() async throws {
        let c = try await LLMTestContext(tokens: 131_072); defer { c.cleanup() }
        c.route.replace([
            .init(status: 400, chunks: [Data(#"{"error":{"param":"max_tokens","message":"max_tokens plus prompt exceeds context window"}}"#.utf8)]),
            .init(status: 422, chunks: [Data(#"{"error":{"param":"stream_options.include_usage","message":"unsupported"}}"#.utf8)]),
            .init(chunks: [try LLMTestFixtures.openAI(#"{"ok":true}"#)])])
        let result = try await c.run()
        XCTAssertEqual(result.attempts, 3); XCTAssertEqual(result.response.usage.totalTokens, 20)
        let bodies = try c.route.requests.map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
        XCTAssertNotNil(bodies[0]["max_tokens"]); XCTAssertNil(bodies[1]["max_tokens"]); XCTAssertNil(bodies[2]["max_tokens"])
        XCTAssertNotNil(bodies[1]["stream_options"]); XCTAssertNil(bodies[2]["stream_options"])
        XCTAssertTrue(bodies.allSatisfy { $0["stream"] as? Bool == true })
    }
    func test128KCodeIterationNegotiatesThenSealsLargeRawHTMLWithoutRepairPermission() async throws {
        let c = try await LLMTestContext(tokens: 131_072); defer { c.cleanup() }
        var draft = c.profile; draft.limits = .init(requestBudget: 3, tokenBudget: 131_072, nativeOutputLimit: false)
        let settings = try await c.settings.settings()
        let saved = try await c.settings.saveProfile(draft, expectedRevision: settings.revision)
        let profile = try XCTUnwrap(saved.profiles.first)
        try await c.credentials.bind(LLMTestFixtures.key, to: profile, settings: c.settings)
        let html = CreatorCodeWorkflowTests.html.replacingOccurrences(of: "</body>", with: "<!--" + String(repeating: "x", count: 70_000) + "--></body>")
        c.route.replace([
            .init(status: 400, chunks: [Data(#"{"error":{"param":"max_tokens","message":"max_tokens exceeds context window"}}"#.utf8)]),
            .init(status: 400, chunks: [Data(#"{"error":{"param":"stream_options","message":"unsupported"}}"#.utf8)]),
            .init(chunks: [try LLMTestFixtures.openAI(html)])])
        let workspace = CreatorWorkspaceTests.workspace(c)
        let request = CreatorOrchestrator.Request(projectID: c.ticket.projectID, profileID: profile.id, configurationID: profile.configurationID,
            prompt: "Create an aurora", maxOutputTokens: 131_072, mode: .code)
        let result = try await workspace.generate(request)
        let conversation = try await c.store.conversation(projectID: result.projectID)
        let turn = try XCTUnwrap(conversation.turns.last)
        XCTAssertEqual(turn.requestCount, 3); XCTAssertEqual(turn.repairCount, 0)
        XCTAssertEqual(turn.reservedOutputTokens, 393_216); XCTAssertEqual(turn.adaptsOutputLimit, true)
        let snapshot = try await c.store.snapshot(projectID: result.projectID, revisionID: result.sealed.id)
        XCTAssertEqual(snapshot.files["index.html"], Data(html.utf8))
        XCTAssertNotNil(snapshot.files["preview.jpg"])
        let first = try JSONSerialization.jsonObject(with: c.route.requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual(first["max_tokens"] as? Int, 131_072)
        XCTAssertNil(first["response_format"])
    }
    func testContextFallbackCannotSendASecondRequestWithOneAttemptBudget() async throws {
        let c = try await LLMTestContext(requests: 1); defer { c.cleanup() }
        c.route.replace([.init(status: 400, chunks: [Data(#"{"error":{"param":"max_tokens","message":"exceeds context"}}"#.utf8)])])
        do { _ = try await c.run(); XCTFail("Budget bypass") } catch { XCTAssertEqual(error as? LLMFailure, .contextWindow) }
        XCTAssertEqual(c.route.requests.count, 1)
    }
    func testRawAndFencedHTMLAndLegacyJSONUseTheSameSourceValidation() throws {
        let html = CreatorCodeWorkflowTests.html.replacingOccurrences(of: "</body>", with: "<!--" + String(repeating: "x", count: 70_000) + "--></body>")
        for raw in [html, "```html\n" + html + "\n```", CreatorCodeWorkflowTests.output(html)] {
            let output = try CreatorCodeOutput.parse(raw)
            XCTAssertEqual(output.html, Data(html.utf8))
        }
        let json = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "title": "Test", "summary": "Legacy", "files": [["path": "index.html", "content": html]]])
        XCTAssertEqual(try CreatorCodeOutput.parse(String(decoding: json, as: UTF8.self)).html, Data(html.utf8))
        for text in ["```html\n" + html, "Explanation\n" + html, html + "trailing", "```html\n" + html + "\n```\n```html\n" + html + "\n```"] {
            XCTAssertThrowsError(try CreatorCodeOutput.parse(text))
        }
        let oversized = html.replacingOccurrences(of: "</body>", with: String(repeating: "x", count: 256 * 1024) + "</body>")
        XCTAssertThrowsError(try CreatorCodeOutput.parse(oversized))
    }
    func testLargeHTMLStreamsAcrossSingleCharacterPrefixesAndSupportsLargeBaseRevision() throws {
        let html = CreatorCodeWorkflowTests.html.replacingOccurrences(of: "</body>", with: "<!--" + String(repeating: "星", count: 40_000) + "--></body>")
        var answer = LLMAnswerBuffer(allowsLeadingThought: true, requiresJSON: false)
        for character in "<think>private planning</think><!doctype html" { try answer.append(String(character)) }
        try answer.append(String(html.dropFirst("<!doctype html".count)))
        XCTAssertEqual(try answer.finish(usage: .init()).text, html)
        let base = CreatorPromptBuilder.Base(revisionID: UUID(), revisionDigest: String(repeating: "a", count: 64), templateID: CreatorCodeOutput.templateID,
            parameters: [:], title: "Test", summary: "Base", source: html)
        let request = try CreatorCodePrompt.build(prompt: "Change the color", base: base, maxOutputTokens: 131_072, repair: nil)
        try request.validate(); XCTAssertFalse(request.requiresJSON)
    }
}
