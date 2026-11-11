import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorPublicationTests: XCTestCase {
    private var root: URL!
    private enum Probe: Error { case interruption }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testOrdinaryImportAndStaleOrMissingEvidenceCannotPublishSealedBytes() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let draft = try await CreatorS14Fixtures.draft(store: store)
        let capture = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: store)
        let sealed = try await store.seal(capture)
        let publication = try await store.publication(projectID: draft.projectID, revisionID: sealed.id)
        let source = root.appendingPathComponent(publication.snapshot.wallpaperID)
        try FileManager.default.copyItem(at: store.bundleURL(projectID: draft.projectID, revisionID: sealed.id), to: source)
        let report = try await WallpaperImportService().importItems([source], into: root.appendingPathComponent("Library"), duplicates: .replaceChanged, progress: { _ in })
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(source, registryURL: root.appendingPathComponent("missing"), publicationRoot: root.appendingPathComponent("publication")))
        try await store.renameProject(draft.projectID, title: "Invalidate evidence")
        do { _ = try await store.publication(projectID: draft.projectID, revisionID: sealed.id); XCTFail("Stale evidence accepted") } catch {}
    }

    func testChangedDraftOrProjectAfterCaptureCannotBeSealed() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let draft = try await CreatorS14Fixtures.draft(store: store)
        let capture = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: store)
        try await store.renameProject(draft.projectID, title: "Changed after capture")
        do { _ = try await store.seal(capture); XCTFail("Stale capture sealed") } catch {}
        let project = try await store.project(draft.projectID)
        XCTAssertEqual(project.revisionIDs, [draft.id])
        XCTAssertNil(project.activeJobID)
    }

    func testFinalPosterAndRegistryTamperingInvalidatePlayback() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let sealed = try await CreatorS14Fixtures.sealed(store: store)
        let registryURL = root.appendingPathComponent("registry.json"), registry = CreatorRuntimeRegistry(url: registryURL)
        let publisher = CreatorPublisher(root: root.appendingPathComponent("publication"), library: root.appendingPathComponent("Library"), registry: registry)
        let installed = try await publisher.publish(projectID: sealed.projectID, revisionID: sealed.id, store: store)
        let poster = installed.appendingPathComponent("preview.jpg"), original = try Data(contentsOf: poster)
        var altered = original; altered[altered.count / 2] ^= 1; try altered.write(to: poster)
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registryURL, publicationRoot: root.appendingPathComponent("publication")))
        try original.write(to: poster)
        let document = try CreatorRuntimeRegistry.read(at: registryURL)
        try await registry.replace(installed.lastPathComponent, expected: document.entries[installed.lastPathComponent], with: nil)
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registryURL, publicationRoot: root.appendingPathComponent("publication")))
    }

    func testPublicationFailuresOnBothSidesOfConfirmationRestoreOrKeepWholeVersion() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let old = try await CreatorS14Fixtures.sealed(store: store)
        let next = try await CreatorS14Fixtures.sealed(store: store, projectID: old.projectID, template: "clock-v2")
        for phase in [CreatorPublisher.Checkpoint.afterImport, .afterRegistry, .afterConfirmation] {
            let scope = root.appendingPathComponent(UUID().uuidString)
            let registry = CreatorRuntimeRegistry(url: scope.appendingPathComponent("registry.json"))
            let library = scope.appendingPathComponent("Library"), journal = scope.appendingPathComponent("publication")
            let clean = CreatorPublisher(root: journal, library: library, registry: registry)
            let installed = try await clean.publish(projectID: old.projectID, revisionID: old.id, store: store)
            let failing = CreatorPublisher(root: journal, library: library, registry: registry, checkpoint: { if $0 == phase { throw Probe.interruption } })
            do { _ = try await failing.publish(projectID: next.projectID, revisionID: next.id, store: store); XCTFail("Interruption swallowed") }
            catch Probe.interruption {}
            let expected = phase == .afterConfirmation ? next : old
            XCTAssertEqual(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry.url, publicationRoot: journal).digest, expected.bundleDigest)
            let bindings = try await registry.bindings()
            XCTAssertEqual(bindings[installed.lastPathComponent]?.revisionID, expected.id)
            try await clean.recover(store: store)
            try await clean.recover(store: store)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.appendingPathComponent("active").path))
        }
    }

    func testRestartAfterImportBeforeJournalAdvanceRestoresBytesAndBinding() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let old = try await CreatorS14Fixtures.sealed(store: store)
        let next = try await CreatorS14Fixtures.sealed(store: store, projectID: old.projectID, template: "gradient-v2")
        let registry = CreatorRuntimeRegistry(url: root.appendingPathComponent("registry.json"))
        let library = root.appendingPathComponent("Library"), journal = root.appendingPathComponent("publication")
        let owner = CreatorPublisher(root: journal, library: library, registry: registry)
        let installed = try await owner.publish(projectID: old.projectID, revisionID: old.id, store: store)
        let interrupted = CreatorPublisher(root: journal, library: library, registry: registry, checkpoint: { if $0 == .afterImport { throw Probe.interruption } })
        let ticket = try await interrupted.prepare(projectID: next.projectID, revisionID: next.id, store: store)
        do { _ = try await interrupted.install(ticket); XCTFail("Import checkpoint not reached") } catch Probe.interruption {}
        XCTAssertEqual(try CreatorDraftStore.read(installed).digest, next.bundleDigest)
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry.url, publicationRoot: journal))
        try await CreatorPublisher(root: journal, library: library, registry: registry).recover()
        XCTAssertEqual(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry.url, publicationRoot: journal).digest, old.bundleDigest)
    }

    func testSealingInterruptionKeepsOriginalDraftAndAtomicReport() async throws {
        for phase in [CreatorRevisionStore.Checkpoint.afterStaging, .afterRevisionMove, .afterProjectCommit] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            let store = CreatorRevisionStore(root: directory)
            let draft = try await CreatorS14Fixtures.draft(store: store)
            let capture = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: store)
            let interrupted = CreatorRevisionStore(root: directory, checkpoint: { if $0 == phase { throw Probe.interruption } })
            do { _ = try await interrupted.seal(capture); XCTFail("Seal checkpoint not reached") } catch Probe.interruption {}
            let project = try await store.project(draft.projectID)
            XCTAssertEqual(project.revisionIDs.count, phase == .afterProjectCommit ? 2 : 1)
            if phase == .afterProjectCommit {
                let report = try await store.report(projectID: draft.projectID, revisionID: project.latestRevisionID!)
                XCTAssertTrue(report.allowsPublication)
            }
            let restored = try await store.recover()
            XCTAssertTrue(restored.invalidRevisions.isEmpty)
        }
    }

    func testLivePublisherRejectsRecoveryAndCancellationRemovesFirstImport() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let sealed = try await CreatorS14Fixtures.sealed(store: store)
        let registry = CreatorRuntimeRegistry(url: root.appendingPathComponent("registry.json"))
        let library = root.appendingPathComponent("Library"), journal = root.appendingPathComponent("publication")
        let publisher = CreatorPublisher(root: journal, library: library, registry: registry)
        let verifying = expectation(description: "Installed bytes and binding await confirmation")
        let task = Task {
            try await publisher.publish(projectID: sealed.projectID, revisionID: sealed.id, store: store) { _ in
                verifying.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [verifying], timeout: 5)
        let installed = library.appendingPathComponent("ai-" + sealed.projectID.uuidString.lowercased())
        XCTAssertThrowsError(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry.url, publicationRoot: journal), "Registration precedes confirmation; a live candidate is not playable")
        do { try await CreatorPublisher(root: journal, library: library, registry: registry).recover(); XCTFail("Recovered a live transaction") }
        catch CreatorPersistence.Failure.busy {}
        task.cancel()
        do { _ = try await task.value; XCTFail("Confirmed cancelled first publication") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        let bindings = try await registry.bindings()
        XCTAssertTrue(bindings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.appendingPathComponent("active").path))
        let retained = try await store.snapshot(projectID: sealed.projectID, revisionID: sealed.id)
        XCTAssertEqual(retained.digest, sealed.bundleDigest)
    }

    func testForeignRegistryChangesArePreservedUntilRecoveryCanMatchOwner() async throws {
        let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        let old = try await CreatorS14Fixtures.sealed(store: store)
        let next = try await CreatorS14Fixtures.sealed(store: store, projectID: old.projectID, template: "clock-v2")
        let registry = CreatorRuntimeRegistry(url: root.appendingPathComponent("registry.json"))
        let library = root.appendingPathComponent("Library"), journal = root.appendingPathComponent("publication")
        let publisher = CreatorPublisher(root: journal, library: library, registry: registry)
        let installed = try await publisher.publish(projectID: old.projectID, revisionID: old.id, store: store)
        let original = try await registry.bindings()[installed.lastPathComponent]
        let ticket = try await publisher.prepare(projectID: next.projectID, revisionID: next.id, store: store)
        _ = try await publisher.install(ticket)
        try await registry.replace(installed.lastPathComponent, expected: original, with: nil)
        do { try await publisher.recover(); XCTFail("Overwrote external registry deletion") }
        catch CreatorPersistence.Failure.staleValidation {}
        XCTAssertEqual(try CreatorDraftStore.read(installed).digest, next.bundleDigest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.appendingPathComponent("active").path))
        let bindings = try await registry.bindings()
        XCTAssertTrue(bindings.isEmpty)
        // Once the external edit is resolved, the same durable journal can restore the old version.
        try await registry.replace(installed.lastPathComponent, expected: nil, with: original)
        try await publisher.recover()
        XCTAssertEqual(try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry.url, publicationRoot: journal).digest, old.bundleDigest)
    }
}
