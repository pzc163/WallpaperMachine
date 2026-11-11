import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorCodeWorkflowTests: XCTestCase {
    nonisolated static let html = #"<!doctype html><html><head><style>html,body{margin:0;overflow:hidden;background:#000}canvas{width:100%;height:100%}</style></head><body><canvas id="c"></canvas><script>const c=document.getElementById('c'),x=c.getContext('2d');function draw(){c.width=320;c.height=180;const g=x.createLinearGradient(0,0,320,180);g.addColorStop(0,'#020208');g.addColorStop(1,'#7020a0');x.fillStyle=g;x.fillRect(0,0,320,180)}draw();addEventListener('pointermove',e=>{window.lastPointer=[e.clientX,e.clientY];draw()});addEventListener('resize',draw);</script></body></html>"#
    static func output(_ html: String = html) -> String {
        "{\"schemaVersion\":2,\"title\":\"紫色水墨\",\"summary\":\"离线互动背景\"}\n<file path=\"index.html\">\n" + html + "\n</file>"
    }
    static func request(_ c: LLMTestContext, base: UUID? = nil, repairs: Int = 0) -> CreatorOrchestrator.Request {
        .init(projectID: c.ticket.projectID, baseRevisionID: base, profileID: c.profile.id, configurationID: c.profile.configurationID,
              prompt: "纯黑背景，随指针变化的紫色水墨", maxOutputTokens: 2048, maxRepairs: repairs, mode: .code)
    }
    func testCodeStreamNegotiationWithoutRepairPermissionStillConsumesWholeTurnBudget() async throws {
        let c = try await LLMTestContext(tokens: 24_576); defer { c.cleanup() }
        c.route.replace([.init(status: 422, chunks: [Data(#"{"error":{"param":"stream","message":"unsupported"}}"#.utf8)]),
            .init(headers: ["Content-Type": "application/json"], chunks: [try LLMStreamingUXTests.nonstream(Self.output())])])
        let workspace = CreatorWorkspaceTests.workspace(c)
        let result = try await workspace.generate(Self.request(c))
        let conversation = try await c.store.conversation(projectID: result.projectID)
        let turn = try XCTUnwrap(conversation.turns.last)
        XCTAssertEqual(turn.requestCount, 2); XCTAssertEqual(turn.repairCount, 0)
        XCTAssertEqual(turn.usesNonStream, true); XCTAssertEqual(turn.state, .completed)
        XCTAssertEqual(turn.attempts.last?.usage?.totalTokens, 19)
        XCTAssertEqual(c.route.requests.count, 2)
    }
    func testThreeProtocolsCreateCapturePublishAndReloadDigestBoundCodeOffline() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let c = try await LLMTestContext(kind: kind, tokens: 8192); defer { c.cleanup() }
            let workspace = CreatorWorkspaceTests.workspace(c)
            c.route.replace([.init(chunks: [try CreatorGenerationFixtures.response(Self.output(), kind: kind)])])
            let result = try await workspace.generate(Self.request(c))
            let report = try await c.store.report(projectID: result.projectID, revisionID: result.sealed.id)
            XCTAssertEqual(report.context.testProfile, "code-runtime-v1"); XCTAssertTrue(report.allowsPublication)
            let installed = try await workspace.publish(project: result.projectID, revision: result.sealed.id)
            let snapshot = try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: c.root.appendingPathComponent("registry.json"), publicationRoot: c.root.appendingPathComponent("publication"))
            XCTAssertEqual(snapshot.manifest?.runtimePolicy, "generatedOfflineV1")
            XCTAssertEqual(snapshot.files["index.html"], Data(Self.html.utf8)); XCTAssertNotNil(snapshot.files["preview.jpg"])
            XCTAssertEqual(result.sealed.outputSchemaVersion, 2)
            let request = try XCTUnwrap(c.route.requests.first?.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            XCTAssertNil(object["response_format"])
            if kind == .geminiGenerateContent { XCTAssertEqual((object["generationConfig"] as? [String: Any])?["responseMimeType"] as? String, "text/plain") }
            let bindings = try await workspace.registry.bindings()
            XCTAssertEqual(bindings.values.first?.runtimePolicy, "generatedOfflineV1")
            try Data((Self.html+" ").utf8).write(to: installed.appendingPathComponent("index.html"))
            XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: c.root.appendingPathComponent("registry.json"), publicationRoot: c.root.appendingPathComponent("publication")))
            XCTAssertEqual(c.route.requests.count, 1)
        }
    }
    func testSyntaxFailureRepairsWithNativeParserEvidenceAndKeepsPriorRevision() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(Self.output())])])
        let first = try await workspace.generate(Self.request(c))
        let original = try await c.store.snapshot(projectID: first.projectID, revisionID: first.sealed.id)
        let bad = Self.html.replacingOccurrences(of: "function draw()", with: "function !!! draw()")
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(Self.output())]), .init(chunks: [try LLMTestFixtures.openAI(Self.output(bad))]), .init(chunks: [try LLMTestFixtures.openAI(Self.output(Self.html.replacingOccurrences(of: "#7020a0", with: "#107080")))])])
        let second = try await workspace.generate(Self.request(c, base: first.sealed.id, repairs: 1))
        let conversation = try await c.store.conversation(projectID: first.projectID)
        XCTAssertEqual(conversation.turns.last?.requestCount, 2)
        XCTAssertEqual(conversation.turns.last?.attempts.first?.issue?.fields.first?.rule, .syntax)
        XCTAssertEqual(second.draft.parentID, first.sealed.id)
        try await workspace.select(project: first.projectID, revision: first.sealed.id)
        let unchanged = try await c.store.snapshot(projectID: first.projectID, revisionID: first.sealed.id)
        XCTAssertEqual(original.digest, unchanged.digest)
        let bodies = c.route.requests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(bodies.last?.contains("Previous immutable revision source") == true)
        XCTAssertFalse(c.diagnostics.lines.joined().contains(LLMTestFixtures.key))
    }
    func testCodeFailureExhaustsThreeAttemptsWithoutChangingPublishedRevisionAnd401StopsImmediately() async throws {
        let c = try await LLMTestContext(tokens: 24576); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(Self.output())])])
        let first = try await workspace.generate(Self.request(c))
        let installed = try await workspace.publish(project: first.projectID, revision: first.sealed.id)
        let original = try CreatorBundleManifest.read(installed).digest
        let malformed = Self.output().replacingOccurrences(of: "index.html", with: "../bad.html")
        let invalid = try LLMTestFixtures.openAI(malformed)
        c.route.replace([.init(), .init(chunks: [invalid]), .init(chunks: [invalid]), .init(chunks: [invalid])])
        do { _ = try await workspace.generate(Self.request(c, base: first.sealed.id, repairs: 2)); XCTFail("Budget ignored") }
        catch let error as CreatorOrchestrator.Failure { XCTAssertEqual(error.requestCount, 3); XCTAssertTrue(error.budgetExhausted) }
        XCTAssertEqual(c.route.requests.count, 4)
        XCTAssertEqual(try CreatorBundleManifest.read(installed).digest, original)
        let project = try await c.store.project(first.projectID)
        XCTAssertEqual(project.selectedRevisionID, first.sealed.id)
        c.route.replace([.init(), .init(), .init(), .init(), .init(status: 401)])
        do { _ = try await workspace.generate(Self.request(c, base: first.sealed.id, repairs: 2)); XCTFail("401 accepted") }
        catch let error as CreatorOrchestrator.Failure { XCTAssertEqual(error.requestCount, 1); XCTAssertEqual(error.issue?.category, .unauthorized) }
        XCTAssertEqual(c.route.requests.count, 5)
    }
    func testCancellationDuringCodeStreamDoesNotPublishOrCreateRevision() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        c.route.replace([.init(hold: true)])
        let task = Task { try await workspace.generate(Self.request(c, repairs: 2)) }
        try await c.waitForRequest(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled code committed") } catch {}
        XCTAssertEqual(c.route.requests.count, 1)
        let project = try await c.store.project(c.ticket.projectID)
        XCTAssertNil(project.latestRevisionID); XCTAssertNil(project.activeJobID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("Library").path))
    }
    func testBlankRuntimeCandidateRequiresFreshModelOutputAndFullPosterValidation() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let blank = "<!doctype html><html><body style='margin:0;background:#000'></body></html>"
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(Self.output(blank))]), .init(chunks: [try LLMTestFixtures.openAI(Self.output())])])
        let result = try await workspace.generate(Self.request(c, repairs: 1))
        let conversation = try await c.store.conversation(projectID: result.projectID)
        XCTAssertEqual(conversation.turns.last?.requestCount, 2)
        XCTAssertEqual(conversation.turns.last?.attempts.first?.issue?.runtimeReason, .invalidCapture)
        let report = try await c.store.report(projectID: result.projectID, revisionID: result.sealed.id)
        XCTAssertTrue(report.allowsPublication)
        let retryBody = String(decoding: try XCTUnwrap(c.route.requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains("invalidCapture"))
        XCTAssertTrue(retryBody.contains("margin:0;background:#000"), "repair receives its failed immutable candidate")
    }
    func testLargeUnicodeSourceSurvivesSplitSSEAndThoughtFilteringWithoutJSONWrapping() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let html = Self.html.replacingOccurrences(of: "</body>", with: "<!--" + String(repeating: "水墨🌙", count: 1900) + "--></body>")
        let response = try LLMTestFixtures.openAI("<think>discarded</think>" + Self.output(html))
        let fragments = stride(from: 0, to: response.count, by: 17).map { Data(response[$0..<min(response.count, $0+17)]) }
        c.route.replace([.init(chunks: fragments)])
        let result = try await workspace.generate(Self.request(c))
        let snapshot = try await c.store.snapshot(projectID: result.projectID, revisionID: result.sealed.id)
        XCTAssertEqual(snapshot.files["index.html"], Data(html.utf8))
        XCTAssertGreaterThan(html.utf8.count, 16 * 1024)
        XCTAssertEqual(c.route.requests.count, 1)
    }
    func testCodeContractRejectsAmbiguousFilesExternalResourcesAndMalformedHeader() throws {
        _ = try CreatorCodeOutput.parse(Self.output())
        for value in [Self.output()+Self.output(), Self.output().replacingOccurrences(of: "index.html", with: "../index.html"),
                      Self.output().replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":1"),
                      Self.output().replacingOccurrences(of: "\"summary\":", with: "\"extra\":0,\"summary\":"),
                      Self.output(Self.html.replacingOccurrences(of: "</body>", with: "<script src='https://example.invalid/x'></script></body>")),
                      Self.output(Self.html+String(repeating: " ", count: CreatorCodeOutput.maximumSourceBytes))] {
            XCTAssertThrowsError(try CreatorCodeOutput.parse(value))
        }
    }
}
