import XCTest
@testable import WallpaperMachine

@MainActor final class LLMNegotiationTests: XCTestCase {
    private func formats(_ c: LLMTestContext) throws -> [String] {
        try c.route.requests.map { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            return (body["response_format"] as? [String: Any])?["type"] as? String ?? "prompt"
        }
    }
    func testConnectionNegotiatesSchemaObjectPromptAndReturnsRealModeAndTime() async throws {
        let c = try await LLMTestContext(tokens: 24_576); defer { c.cleanup() }
        let body = Data(#"{"error":{"message":"response_format not supported"}}"#.utf8)
        let answer = "<think>private reasoning never stored</think>" + CreatorGenerationFixtures.fenced(#"{"ok":true}"#)
        c.route.replace([.init(status: 400, chunks: [body]), .init(status: 422, chunks: [body]),
                         .init(chunks: [try LLMTestFixtures.openAI(answer)])])
        let workspace = CreatorWorkspaceTests.workspace(c)
        let projects = try await workspace.projects().map(\.id)
        let result = try await workspace.testConnection(c.profile)
        XCTAssertEqual(try formats(c), ["json_schema", "json_object", "prompt"])
        XCTAssertEqual(result.mode, .disabled); XCTAssertEqual(result.attempts, 3)
        XCTAssertEqual(result.model, c.profile.model); XCTAssertGreaterThanOrEqual(result.elapsed, 0)
        XCTAssertEqual(result.usage.outputTokens, 8)
        let after = try await workspace.projects().map(\.id); XCTAssertEqual(projects, after)
        XCTAssertFalse(c.diagnostics.lines.joined().contains("private reasoning"))
        for request in c.route.requests {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        }
    }
    func testStrictShapeFailureNegotiatesAndStillRequiresNativeContract() async throws {
        let c = try await LLMTestContext(tokens: 192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(#"{"nested":{"ok":true}}"#)]),
                         .init(chunks: [try LLMTestFixtures.openAI(#"{"ok":true}"#)])])
        let result = try await CreatorWorkspaceTests.workspace(c).testConnection(c.profile)
        XCTAssertEqual(result.attempts, 2); XCTAssertEqual(result.mode, .required)
        XCTAssertEqual(try formats(c), ["json_schema", "json_object"])
    }
    func testNegotiationCannotExceedRequestBudgetAnd401NeverFallsBack() async throws {
        for status in [400, 401, 422] {
            let c = try await LLMTestContext(requests: 1, tokens: 8192); defer { c.cleanup() }
            c.route.replace([.init(status: status, chunks: [Data(#"{"error":{"message":"response_format unsupported"}}"#.utf8)])])
            do { _ = try await CreatorWorkspaceTests.workspace(c).testConnection(c.profile); XCTFail("Unexpected success") } catch {}
            XCTAssertEqual(c.route.requests.count, 1)
        }
    }
    func testNativeParameterValidationParticipatesInSameProviderNegotiation() async throws {
        let c = try await LLMTestContext(tokens: 192); defer { c.cleanup() }
        let valid = try CreatorGenerationFixtures.output("clock-v2")
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(#"{"parameters":{}}"#)]),
                         .init(chunks: [try LLMTestFixtures.openAI(valid)])])
        let input = try CreatorPromptBuilder.build(prompt: "时钟", base: nil, maxOutputTokens: 64)
        let result = try await c.provider.generate(input, profileID: c.profile.id, configurationID: c.profile.configurationID,
            ticket: c.ticket, store: c.store, validate: { _ = try CreatorOutputValidator.detailed($0) })
        XCTAssertEqual(result.attempts, 2); XCTAssertEqual(result.reservedOutputTokens, 128)
        XCTAssertEqual(try formats(c), ["json_schema", "json_object"])
        XCTAssertEqual(try CreatorOutputValidator.parse(result.response.text).templateID, "clock-v2")
    }

    func testCancellationDuringNegotiationStopsWithoutThirdRequest() async throws {
        let c = try await LLMTestContext(tokens: 24_576); defer { c.cleanup() }
        c.route.replace([.init(status: 400, chunks: [Data(#"{"error":{"message":"response_format unsupported"}}"#.utf8)]),
                         .init(hold: true)])
        let workspace = CreatorWorkspaceTests.workspace(c)
        let task = Task { try await workspace.testConnection(c.profile) }
        let end = ContinuousClock.now + .seconds(3)
        while c.route.requests.count < 2 && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(c.route.requests.count, 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled negotiation succeeded") }
        catch { XCTAssertEqual(error as? LLMFailure, .cancelled) }
        XCTAssertEqual(c.route.requests.count, 2)
    }
}
