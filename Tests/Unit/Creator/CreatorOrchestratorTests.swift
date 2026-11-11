import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorOrchestratorTests: XCTestCase {
    private func make(_ c: LLMTestContext, capture: CreatorOrchestrator.Capture? = nil,
                      checkpoint: @escaping @Sendable (CreatorOrchestrator.Stage) async throws -> Void = { _ in }) -> CreatorOrchestrator {
        let registry = CreatorRuntimeRegistry(url: c.root.appendingPathComponent("registry.json"))
        let publisher = CreatorPublisher(root: c.root.appendingPathComponent("publication"), library: c.root.appendingPathComponent("Library"), registry: registry)
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        if let capture { return CreatorOrchestrator(store: c.store, generator: generator, publisher: publisher, capture: capture, checkpoint: checkpoint) }
        return CreatorOrchestrator(store: c.store, generator: generator, publisher: publisher, checkpoint: checkpoint)
    }
    private func request(_ c: LLMTestContext, projectID: UUID? = nil, base: UUID? = nil) -> CreatorOrchestrator.Request {
        .init(projectID: projectID, title: "Local creation", baseRevisionID: base, profileID: c.profile.id,
              configurationID: c.profile.configurationID, prompt: "深蓝色星空，缓慢变化", maxOutputTokens: 2048)
    }

    func testThreeProtocolsAndTemplatesCompleteRealSnapshotImportAndCoverRead() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let c = try await LLMTestContext(kind: kind, requests: 1, tokens: 4096); defer { c.cleanup() }
            let flow = make(c)
            for template in CreatorTemplateCatalog.all {
                let requestCount = c.route.requests.count
                c.route.replace([.init(chunks: [try CreatorGenerationFixtures.response(CreatorGenerationFixtures.output(template.id), kind: kind)])])
                let result = try await flow.createAndSave(request(c))
                let installed = try CreatorRuntimeRegistry.readForPlayback(result.installedDirectory, registryURL: c.root.appendingPathComponent("registry.json"), publicationRoot: c.root.appendingPathComponent("publication"))
                let publication = try await c.store.publication(projectID: result.projectID, revisionID: result.sealed.id)
                XCTAssertEqual(installed.digest, result.sealed.bundleDigest)
                XCTAssertEqual(installed.files.count, 4)
                XCTAssertTrue(publication.binding.report?.allowsPublication == true)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: installed.files["project.json"]!) as? [String: Any])
                let preview = try XCTUnwrap(json["preview"] as? String)
                let url = try LibraryPreviewFetcher.identity(of: result.installedDirectory.appendingPathComponent(preview), in: c.root.appendingPathComponent("Library"))
                let cover = try await LibraryPreviewFetcher(root: c.root.appendingPathComponent("Library")).fetch(url)
                XCTAssertEqual(cover, installed.files["preview.jpg"])
                try CreatorBundleManifest.validatePoster(cover)
                XCTAssertEqual(result.sealed.generation, result.draft.generation)
                XCTAssertEqual(result.sealed.generation?.attemptCount, 1)
                XCTAssertEqual(result.sealed.generation?.reservedOutputTokens, 2048)
                let project = try await c.store.project(result.projectID)
                XCTAssertEqual(project.publishedWallpaperID, installed.wallpaperID)
                XCTAssertEqual(project.revisionIDs, [result.draft.id, result.sealed.id])
                XCTAssertEqual(c.route.requests.count, requestCount + 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("publication/active").path))
            }
        }
    }

    func testModificationKeepsOldBytesAndReusesInstalledIdentity() async throws {
        let c = try await LLMTestContext(requests: 1, tokens: 4096); defer { c.cleanup() }
        let flow = make(c)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let first = try await flow.createAndSave(request(c))
        let original = try await c.store.snapshot(projectID: first.projectID, revisionID: first.sealed.id)
        let oldReport = try await c.store.report(projectID: first.projectID, revisionID: first.sealed.id)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output("clock-v2"))])])
        let second = try await flow.createAndSave(request(c, projectID: first.projectID, base: first.sealed.id))
        XCTAssertEqual(first.installedDirectory, second.installedDirectory)
        XCTAssertEqual(second.draft.parentID, first.sealed.id)
        XCTAssertEqual(second.sealed.parentID, second.draft.id)
        let preserved = try await c.store.snapshot(projectID: first.projectID, revisionID: first.sealed.id)
        let preservedReport = try await c.store.report(projectID: first.projectID, revisionID: first.sealed.id)
        XCTAssertEqual(preserved.files, original.files)
        XCTAssertEqual(preservedReport, oldReport)
        XCTAssertEqual(try CreatorDraftStore.read(second.installedDirectory).digest, second.sealed.bundleDigest)
        let restored = try await flow.recover()
        XCTAssertTrue(restored.invalidRevisions.isEmpty)
    }

    func testRuntimeFailurePreservesInstalledVersionAndNewRecoverableDraft() async throws {
        let c = try await LLMTestContext(requests: 1, tokens: 4096); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let original = try await make(c).createAndSave(request(c))
        let binding = try CreatorRuntimeRegistry.read(at: c.root.appendingPathComponent("registry.json"))
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output("clock-v2"))])])
        let flow = make(c, capture: { _, _, _ in throw CreatorRuntimeFailure.timeout })
        do { _ = try await flow.createAndSave(request(c, projectID: original.projectID, base: original.sealed.id)); XCTFail("Runtime failure published") }
        catch { XCTAssertEqual((error as? CreatorOrchestrator.Failure)?.stage, .runtime) }
        XCTAssertEqual(try CreatorDraftStore.read(original.installedDirectory).digest, original.sealed.bundleDigest)
        XCTAssertEqual(try CreatorRuntimeRegistry.read(at: c.root.appendingPathComponent("registry.json")), binding)
        let project = try await c.store.project(original.projectID)
        XCTAssertEqual(project.revisionIDs.count, 3)
        let latest = try await c.store.snapshot(projectID: project.id, revisionID: project.latestRevisionID!)
        XCTAssertEqual(latest.manifest?.packaging, .renderDraft)
        XCTAssertEqual(c.route.requests.count, 2)
    }

    func testCancellationAtEachFlowStageNeverPublishesAHalfPackage() async throws {
        for stage in [CreatorOrchestrator.Stage.generating, .runtime, .sealing, .publishing] {
            let c = try await LLMTestContext(requests: 1, tokens: 4096); defer { c.cleanup() }
            c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
            let flow = make(c, checkpoint: { if $0 == stage { throw CancellationError() } })
            do { _ = try await flow.createAndSave(request(c)); XCTFail("Cancellation ignored") }
            catch { XCTAssertEqual((error as? CreatorOrchestrator.Failure)?.code, "cancelled") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("Library").path))
            XCTAssertTrue(try CreatorRuntimeRegistry.read(at: c.root.appendingPathComponent("registry.json")).entries.isEmpty)
            XCTAssertEqual(c.route.requests.count, stage == .generating ? 0 : 1)
        }
    }

    func testInstalledPageRetainsFrozenSchemeAndRejectsDeletedRegistryOnReload() async throws {
        let c = try await LLMTestContext(requests: 1, tokens: 4096); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let result = try await make(c).createAndSave(request(c))
        let directory = result.installedDirectory, registry = c.root.appendingPathComponent("registry.json"), journal = c.root.appendingPathComponent("publication")
        let page = WebWallpaperPage(projectURL: directory, entryFile: "index.html")
        defer { page.stop() }
        page.webView.setFrameSize(NSSize(width: 320, height: 180))
        page.creatorSnapshotLoader = { try CreatorRuntimeRegistry.readForPlayback(directory, registryURL: registry, publicationRoot: journal) }
        let ready = expectation(description: "Installed page ready")
        page.onLoaded = { ready.fulfill() }
        page.load()
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNil(page.webView.window)
        XCTAssertFalse(page.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertNotNil(page.webView.configuration.urlSchemeHandler(forURLScheme: CreatorWebResources.scheme))
        XCTAssertEqual(page.webView.url, CreatorWebResources.entryURL)
        try FileManager.default.removeItem(at: registry)
        let refused = expectation(description: "Unregistered reload refused")
        page.onFailure = { _ in refused.fulfill() }; page.onLoaded = { XCTFail("Reload bypassed registry") }
        page.load()
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertFalse(page.isLoaded)
    }
}
