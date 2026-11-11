import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorIterationTests: XCTestCase {
    private func flow(_ c: LLMTestContext, capture: CreatorOrchestrator.Capture? = nil) -> CreatorOrchestrator {
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        let publisher = CreatorPublisher(root: c.root.appendingPathComponent("publication"), library: c.root.appendingPathComponent("Library"),
            registry: CreatorRuntimeRegistry(url: c.root.appendingPathComponent("registry.json")))
        if let capture { return CreatorOrchestrator(store: c.store, generator: generator, publisher: publisher, capture: capture) }
        return CreatorOrchestrator(store: c.store, generator: generator, publisher: publisher)
    }
    private func request(_ c: LLMTestContext, base: UUID? = nil, repairs: Int = 0) -> CreatorOrchestrator.Request {
        .init(projectID: c.ticket.projectID, baseRevisionID: base, profileID: c.profile.id, configurationID: c.profile.configurationID,
              prompt: "改成紫色，减少粒子", maxOutputTokens: 2048, maxRepairs: repairs)
    }
    @discardableResult private func response(_ c: LLMTestContext, _ text: String, hold: Bool = false) throws -> LLMMockURLProtocol.Route {
        let route = LLMMockURLProtocol.Route([.init(chunks: [try LLMTestFixtures.openAI(text)], hold: hold)])
        LLMMockURLProtocol.register(route, at: c.url)
        return route
    }

    func testExplicitOldBaseAndRollbackPreserveEveryRevisionAndInstalledSelection() async throws {
        let c = try await LLMTestContext(tokens: 16_384); defer { c.cleanup() }
        let owner = flow(c)
        try response(c, CreatorGenerationFixtures.output())
        let first = try await owner.createAndSave(request(c))
        let original = try await c.store.snapshot(projectID: first.projectID, revisionID: first.sealed.id)
        try response(c, CreatorGenerationFixtures.output("clock-v2"))
        let second = try await owner.createAndSave(request(c, base: first.sealed.id))
        let selected = try await owner.selectRevision(projectID: first.projectID, revisionID: first.sealed.id)
        XCTAssertEqual(selected.id, first.sealed.id)
        let project = try await c.store.project(first.projectID)
        XCTAssertEqual(project.selectedRevisionID, first.sealed.id)
        XCTAssertEqual(project.latestRevisionID, second.sealed.id)
        XCTAssertEqual(try CreatorDraftStore.read(first.installedDirectory).digest, second.sealed.bundleDigest)
        let preview = try await CreatorPreview.make(projectID: first.projectID, revisionID: project.selectedRevisionID!, store: c.store)
        defer { preview.surface.stop() }
        XCTAssertEqual(preview.snapshot.files, original.files)
        try response(c, CreatorGenerationFixtures.output("gradient-v2"))
        let third = try await owner.createAndSave(request(c, base: first.sealed.id))
        XCTAssertEqual(third.draft.parentID, first.sealed.id)
        XCTAssertNotEqual(third.draft.parentID, second.sealed.id)
        let stillOriginal = try await c.store.snapshot(projectID: first.projectID, revisionID: first.sealed.id)
        XCTAssertEqual(stillOriginal.files, original.files)
        let history = try await c.store.conversation(projectID: first.projectID)
        XCTAssertEqual(history.turns.count, 3)
        XCTAssertEqual(history.turns.map(\.baseRevisionID), [nil, first.sealed.id, first.sealed.id])
        let restored = try await CreatorRevisionStore(root: c.store.root).conversation(projectID: first.projectID)
        XCTAssertEqual(restored, history)
        let bundleNames = try FileManager.default.contentsOfDirectory(atPath: third.installedDirectory.path)
        XCTAssertFalse(bundleNames.contains("conversation.json"))
    }

    func testFailedSecondVersionAndRestartKeepLastFullyValidatedVersion() async throws {
        let c = try await LLMTestContext(tokens: 16_384); defer { c.cleanup() }
        try response(c, CreatorGenerationFixtures.output())
        let first = try await flow(c).createAndSave(request(c))
        let binding = try CreatorRuntimeRegistry.read(at: c.root.appendingPathComponent("registry.json"))
        let route = try response(c, CreatorGenerationFixtures.output("clock-v2"))
        let owner = flow(c, capture: { _, _, _ in throw CreatorRuntimeFailure.timeout })
        do { _ = try await owner.createAndSave(request(c, base: first.sealed.id, repairs: 2)); XCTFail("Runtime failure published") }
        catch { XCTAssertTrue((error as? CreatorOrchestrator.Failure)?.budgetExhausted == true) }
        XCTAssertEqual(route.requests.count, 3)
        let project = try await c.store.project(first.projectID)
        XCTAssertEqual(project.revisionIDs.count, 5)
        XCTAssertEqual(project.selectedRevisionID, first.sealed.id)
        XCTAssertEqual(project.lastValidatedRevisionID, first.sealed.id)
        let recovered = CreatorRevisionStore(root: c.store.root)
        let recovery = try await recovered.recover()
        XCTAssertTrue(recovery.invalidRevisions.isEmpty)
        let reopened = try await recovered.project(first.projectID)
        XCTAssertEqual(reopened.selectedRevisionID, first.sealed.id)
        XCTAssertEqual(reopened.lastValidatedRevisionID, first.sealed.id)
        XCTAssertEqual(try CreatorDraftStore.read(first.installedDirectory).digest, first.sealed.bundleDigest)
        XCTAssertEqual(try CreatorRuntimeRegistry.read(at: c.root.appendingPathComponent("registry.json")), binding)
        _ = try await owner.selectRevision(projectID: first.projectID, revisionID: first.sealed.id)
    }

    func testRollbackCancelsHeldModificationAndRejectsLateCompletion() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let owner = flow(c)
        try response(c, CreatorGenerationFixtures.output())
        let first = try await owner.createAndSave(request(c))
        let held = try response(c, CreatorGenerationFixtures.output("clock-v2"), hold: true)
        let task = Task { try await owner.createAndSave(request(c, base: first.sealed.id, repairs: 2)) }
        let end = ContinuousClock.now + .seconds(3)
        while held.requests.isEmpty && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(held.requests.count, 1)
        _ = try await owner.selectRevision(projectID: first.projectID, revisionID: first.sealed.id)
        do { _ = try await task.value; XCTFail("Cancelled modification completed") }
        catch { XCTAssertEqual((error as? CreatorOrchestrator.Failure)?.issue?.category, .cancelled) }
        let project = try await c.store.project(first.projectID)
        XCTAssertEqual(project.revisionIDs.count, 2); XCTAssertEqual(project.selectedRevisionID, first.sealed.id)
        XCTAssertGreaterThan(held.stopCount, 0)
        let history = try await c.store.conversation(projectID: first.projectID)
        XCTAssertEqual(history.turns.last?.state, .cancelled)
    }

    func testUnknownOrTamperedRevisionCannotReplaceWorkingTarget() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        try response(c, CreatorGenerationFixtures.output())
        let owner = flow(c), first = try await owner.createAndSave(request(c))
        do { _ = try await owner.selectRevision(projectID: first.projectID, revisionID: UUID()); XCTFail("Unknown target selected") } catch {}
        let project = try await c.store.project(first.projectID)
        XCTAssertEqual(project.selectedRevisionID, first.sealed.id)
        let file = c.store.bundleURL(projectID: first.projectID, revisionID: first.draft.id).appendingPathComponent("index.html")
        try Data("altered".utf8).write(to: file)
        do { _ = try await owner.selectRevision(projectID: first.projectID, revisionID: first.draft.id); XCTFail("Tampered target selected") } catch {}
        let after = try await c.store.project(first.projectID)
        XCTAssertEqual(after.selectedRevisionID, first.sealed.id)
    }
}
