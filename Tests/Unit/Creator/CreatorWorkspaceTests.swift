import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorWorkspaceTests: XCTestCase {
    static func workspace(_ c: LLMTestContext, capture: CreatorOrchestrator.Capture? = nil) -> CreatorWorkspace {
        let registry = CreatorRuntimeRegistry(url: c.root.appendingPathComponent("registry.json"))
        let publisher = CreatorPublisher(root: c.root.appendingPathComponent("publication"), library: c.root.appendingPathComponent("Library"), registry: registry)
        if let capture {
            return CreatorWorkspace(store: c.store, settings: c.settings, credentials: c.credentials, provider: c.provider,
                publisher: publisher, registry: registry, library: c.root.appendingPathComponent("Library"), capture: capture, beforeWrite: {})
        }
        return CreatorWorkspace(store: c.store, settings: c.settings, credentials: c.credentials, provider: c.provider,
            publisher: publisher, registry: registry, library: c.root.appendingPathComponent("Library"), beforeWrite: {})
    }
    static func request(_ c: LLMTestContext) -> CreatorOrchestrator.Request {
        .init(projectID: c.ticket.projectID, profileID: c.profile.id, configurationID: c.profile.configurationID, prompt: "Quiet stars", maxOutputTokens: 2048)
    }
    static func response(_ c: LLMTestContext) throws {
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
    }
    func testGenerateStopsAtFullRuntimeEvidenceWithoutPublishing() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = Self.workspace(c); try Self.response(c)
        let result = try await workspace.generate(Self.request(c))
        XCTAssertNil(result.installedDirectory)
        let report = try await c.store.report(projectID: result.projectID, revisionID: result.sealed.id)
        XCTAssertTrue(report.allowsPublication)
        let conversation = try await c.store.conversation(projectID: result.projectID)
        XCTAssertEqual(conversation.turns.last?.state, .completed)
        XCTAssertEqual(c.route.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("Library").path))
        let bindings = try await workspace.registry.bindings(); XCTAssertTrue(bindings.isEmpty)
    }
    func testPublishAndDeleteDraftKeepInstalledPolicyAndBytes() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = Self.workspace(c); try Self.response(c)
        let result = try await workspace.generate(Self.request(c))
        let url = try await workspace.publish(project: result.projectID, revision: result.sealed.id)
        let id = try await workspace.installedWallpaper(project: result.projectID, revision: result.sealed.id)
        XCTAssertEqual(id, url.lastPathComponent)
        try await workspace.delete(result.projectID)
        let snapshot = try CreatorRuntimeRegistry.readForPlayback(url, registryURL: c.root.appendingPathComponent("registry.json"), publicationRoot: c.root.appendingPathComponent("publication"))
        XCTAssertEqual(snapshot.digest, result.sealed.bundleDigest)
        let recovery = try await workspace.recover(); XCTAssertTrue(recovery.invalidJobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.projectURL(result.projectID).path))
    }
    func testDisplayRenameAndDuplicatePreserveValidatedHistory() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = Self.workspace(c)
        let original = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
        let before = try await c.store.report(projectID: original.projectID, revisionID: original.id)
        try await workspace.rename(original.projectID, title: "Renamed project")
        let after = try await c.store.report(projectID: original.projectID, revisionID: original.id)
        XCTAssertEqual(before, after)
        let rows = try await workspace.projects(); XCTAssertEqual(rows.first?.title, "Renamed project")
        let copyID = try await workspace.duplicate(original.projectID, title: "Independent copy")
        XCTAssertNotEqual(copyID, original.projectID)
        let detail = try await workspace.detail(copyID)
        let selected = try XCTUnwrap(detail.project.selectedRevisionID)
        XCTAssertTrue(detail.reports[selected]?.allowsPublication == true)
        XCTAssertNil(detail.project.publishedWallpaperID)
        XCTAssertTrue(c.route.requests.isEmpty)
        let originalAgain = try await c.store.report(projectID: original.projectID, revisionID: original.id)
        XCTAssertEqual(before, originalAgain)
    }
    func testPropertyChangesCreateANewVerifiedRevisionAndRejectInvalidParameters() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = Self.workspace(c)
        let original = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
        let snapshot = try await c.store.snapshot(projectID: original.projectID, revisionID: original.id)
        var values = try XCTUnwrap(snapshot.specification.parameters); values["starDensity"] = .number(0.1)
        let edited = try await workspace.edit(project: original.projectID, revision: original.id, parameters: values)
        let report = try await c.store.report(projectID: original.projectID, revisionID: edited.id)
        XCTAssertTrue(report.allowsPublication); XCTAssertNotEqual(edited.bundleDigest, original.bundleDigest)
        values["starDensity"] = .number(999)
        do { _ = try await workspace.edit(project: original.projectID, revision: edited.id, parameters: values); XCTFail("Accepted range violation") } catch {}
        let old = try await c.store.snapshot(projectID: original.projectID, revisionID: original.id)
        XCTAssertEqual(snapshot.digest, old.digest); XCTAssertTrue(c.route.requests.isEmpty)
    }
    func testFailedPropertyRuntimeKeepsPreviousSelectionAndLastValidatedVersion() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let original = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
        let workspace = Self.workspace(c, capture: { _, _, _ in throw CreatorRuntimeFailure.timeout })
        let snapshot = try await c.store.snapshot(projectID: original.projectID, revisionID: original.id)
        do { _ = try await workspace.edit(project: original.projectID, revision: original.id, parameters: snapshot.specification.parameters!); XCTFail("Runtime accepted") } catch {}
        let project = try await c.store.project(original.projectID)
        XCTAssertEqual(project.selectedRevisionID, original.id); XCTAssertEqual(project.lastValidatedRevisionID, original.id)
    }
    func testRestartFinishesCommittedDraftDeletion() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        try await c.store.cancel(c.ticket)
        let retired = c.store.projectsURL.appendingPathComponent(".deleted-" + CreatorPersistence.uuidName(c.ticket.projectID))
        try FileManager.default.moveItem(at: c.store.projectURL(c.ticket.projectID), to: retired)
        let recovery = try await c.store.recover()
        XCTAssertTrue(recovery.invalidProjects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    }
    func testChangedProfileCannotUseOldKeyOrSendPacket() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = Self.workspace(c)
        let settings = try await workspace.configuration()
        var changed = c.profile; changed.baseURL = "https://other.invalid"
        let next = try await workspace.saveProfile(changed, key: "", expectedRevision: settings.revision)
        let profile = try XCTUnwrap(next.profiles.first)
        XCTAssertNotEqual(profile.configurationID, c.profile.configurationID)
        do { _ = try await workspace.testConnection(profile); XCTFail("Old credentials transferred") } catch {}
        XCTAssertTrue(c.route.requests.isEmpty)
        XCTAssertFalse(try String(contentsOf: c.settings.url, encoding: .utf8).contains(LLMTestFixtures.key))
    }
    func testConnectionProbeHasOneRequestAndNoPersistentProject() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(#"{"ok":true}"#)])])
        let workspace = Self.workspace(c)
        let before = try await workspace.projects().map(\.id)
        _ = try await workspace.testConnection(c.profile)
        XCTAssertEqual(c.route.requests.count, 1)
        let after = try await workspace.projects().map(\.id); XCTAssertEqual(before, after)
        XCTAssertFalse(c.diagnostics.lines.joined().contains(LLMTestFixtures.key))
    }
    func testSchemaConnectionCheckKeepsOneRequestAndUsesItsOwnSmallSchema() async throws {
        let c = try await LLMTestContext(tokens: 8192, capabilities: .init(jsonMode: .schema)); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(#"{"ok":true}"#)])])
        let workspace = Self.workspace(c)
        let before = try await workspace.projects().map(\.id)
        _ = try await workspace.testConnection(c.profile)
        XCTAssertEqual(c.route.requests.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(c.route.requests.first?.httpBody)) as? [String: Any])
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "connection_check")
        let after = try await workspace.projects().map(\.id); XCTAssertEqual(before, after)
    }

    func testUnpublishedNewRevisionCannotApplyOlderInstalledVersion() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = Self.workspace(c)
        let first = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
        _ = try await workspace.publish(project: first.projectID, revision: first.id)
        let second = try await CreatorS14Fixtures.sealed(store: c.store, projectID: first.projectID, template: "clock-v2")
        do { _ = try await workspace.installedWallpaper(project: first.projectID, revision: second.id); XCTFail("Applied stale library version") } catch {}
    }
}
