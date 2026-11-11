import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorRuntimeRegistryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRegistryPersistsLegacyBindingsAndBlocksChangedRestoredBytesOrUnknownPolicy() async throws {
        let drafts = CreatorDraftStore(root: root.appendingPathComponent("Library"))
        let directory = try await drafts.create(.init(projectID: UUID(), kind: .stars))
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let revision = try await store.importLegacy(directory, title: "Registry")
        _ = try await store.validate(projectID: revision.projectID, revisionID: revision.id)
        let url = root.appendingPathComponent("support/CreatorRuntimeRegistry.json")
        let registry = CreatorRuntimeRegistry(url: url)
        try await registry.registerLegacy(projectID: revision.projectID, revisionID: revision.id, store: store, installedDirectory: directory)
        let restarted = CreatorRuntimeRegistry(url: url)
        let bindings = try await restarted.bindings()
        XCTAssertEqual(bindings[directory.lastPathComponent]?.bundleDigest, revision.bundleDigest)
        XCTAssertEqual(try CreatorRuntimeRegistry.readForPlayback(directory, registryURL: url, publicationRoot: root.appendingPathComponent("publication")).digest, revision.bundleDigest)
        // A valid but older/different native template also fails the registry's content binding.
        let changed = try CreatorTemplate.files(for: .init(projectID: revision.projectID, kind: .clock))
        for (name, data) in changed { try data.write(to: directory.appendingPathComponent(name)) }
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(directory, registryURL: url, publicationRoot: root.appendingPathComponent("publication")))
        var document = try CreatorRuntimeRegistry.read(at: url)
        let key = directory.lastPathComponent
        let binding = try XCTUnwrap(document.entries[key])
        document.entries[key] = .init(schemaVersion: 1, wallpaperID: key, projectID: binding.projectID,
            revisionID: binding.revisionID, bundleVersion: 1, bundleDigest: binding.bundleDigest,
            runtimePolicy: "generatedOfflineV1", context: binding.context)
        try CreatorPersistence.write(document, to: url)
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(directory, registryURL: url, publicationRoot: root.appendingPathComponent("publication")))
    }

    func testRenamedBundlesAndReservedIDsCannotSelectCompatibilityHost() async throws {
        let drafts = CreatorDraftStore(root: root.appendingPathComponent("drafts"))
        let directory = try await drafts.create(.init(projectID: UUID(), kind: .stars))
        let renamed = root.appendingPathComponent("renamed")
        try FileManager.default.copyItem(at: directory, to: renamed)
        for folder in [renamed, root.appendingPathComponent("ai-unknown"), root.appendingPathComponent("creator-s0-unknown")] {
            XCTAssertTrue(CreatorRuntimeRegistry.isCandidate(folder))
            let page = WebWallpaperPage(projectURL: folder, entryFile: "index.html")
            defer { page.stop() }
            XCTAssertFalse(page.webView.configuration.websiteDataStore.isPersistent)
            XCTAssertNotNil(page.webView.configuration.urlSchemeHandler(forURLScheme: CreatorWebResources.scheme))
            XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(folder, registryURL: root.appendingPathComponent("missing-registry.json"), publicationRoot: root.appendingPathComponent("publication")))
        }
    }

    func testRevisionPreviewUsesFrozenSchemeAndRejectsChangedReportOnReload() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let project = try await store.createProject(title: "Preview")
        let ticket = try await store.beginJob(projectID: project.id)
        let definition = try CreatorTemplateCatalog.definition("stars-v2")
        _ = try await store.stage(definition.specification(projectID: project.id), for: ticket)
        let revision = try await store.commit(ticket)
        do { _ = try await CreatorPreview.make(projectID: project.id, revisionID: revision.id, store: store); XCTFail("Previewed without validation") } catch {}
        _ = try await store.validate(projectID: project.id, revisionID: revision.id)
        let result = try await CreatorPreview.make(projectID: project.id, revisionID: revision.id, store: store)
        let surface = result.surface
        defer { surface.stop() }
        surface.view.setFrameSize(NSSize(width: 320, height: 180))
        surface.view.layoutSubtreeIfNeeded()
        try await surface.start()
        let deadline = Date().addingTimeInterval(10)
        while !surface.page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(surface.page.isLoaded)
        XCTAssertEqual(surface.page.webView.url, CreatorWebResources.entryURL)
        XCTAssertNil(surface.page.webView.window)
        let canvas = try await surface.page.webView.evaluateJavaScript("document.querySelector('canvas') !== null") as? Bool
        XCTAssertEqual(canvas, true)
        let failed = expectation(description: "Reload refuses invalidated metadata")
        surface.page.onFailure = { _ in failed.fulfill() }
        try await store.renameProject(project.id, title: "Changed metadata")
        surface.page.load()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(surface.page.isLoaded)
    }

    func testV2DraftCannotEnterFormalPlaybackOrRegistry() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let project = try await store.createProject(title: "Draft only")
        let ticket = try await store.beginJob(projectID: project.id)
        _ = try await store.stage(.init(projectID: project.id, kind: .clock), for: ticket)
        let revision = try await store.commit(ticket)
        _ = try await store.validate(projectID: project.id, revisionID: revision.id)
        let snapshot = try await store.snapshot(projectID: project.id, revisionID: revision.id)
        let directory = root.appendingPathComponent("ai-" + project.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in snapshot.files { try data.write(to: directory.appendingPathComponent(name)) }
        let url = root.appendingPathComponent("registry.json")
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(directory, registryURL: url, publicationRoot: root.appendingPathComponent("publication")))
        do {
            try await CreatorRuntimeRegistry(url: url).registerLegacy(projectID: project.id, revisionID: revision.id, store: store, installedDirectory: directory)
            XCTFail("Registered draft as a published package")
        } catch {}
        do {
            try await WallpaperPlaybackPreflight.check(wallpaperID: directory.lastPathComponent, library: root) { _ in
                XCTFail("Creator draft reached video compatibility path")
                return .supported
            }
            XCTFail("Draft passed formal preflight")
        } catch {}
    }
}
