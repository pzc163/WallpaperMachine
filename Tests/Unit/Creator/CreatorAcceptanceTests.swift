import XCTest
@testable import WallpaperMachine

/// AC-09/10/13/14 operate real storage and playback checks without a display or panel.
@MainActor
final class CreatorAcceptanceTests: XCTestCase {
    private var root: URL!
    private var store: CreatorRevisionStore!
    private var registry: CreatorRuntimeRegistry!
    private var publisher: CreatorPublisher!
    private var library: URL { root.appendingPathComponent("Library") }
    private var journal: URL { root.appendingPathComponent("Creator/Publication") }
    private enum Probe: Error { case interrupted }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-acceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        registry = CreatorRuntimeRegistry(url: root.appendingPathComponent("registry.json"))
        publisher = CreatorPublisher(root: journal, library: library, registry: registry)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func playback(_ directory: URL) throws -> CreatorDraftStore.Snapshot {
        try CreatorRuntimeRegistry.readForPlayback(directory, registryURL: registry.url, publicationRoot: journal)
    }
    private func preflight(_ directory: URL) async throws {
        try await WallpaperPlaybackPreflight.check(wallpaperID: directory.lastPathComponent, library: library,
            creatorRegistryURL: registry.url, creatorPublicationRoot: journal, videoFormat: { _ in fatalError("Creator routed to video") })
    }
    func testUnconfirmedRegistryCannotPlayAndHeadlessRecoveryRestoresPreviousSelection() async throws {
        let first = try await CreatorS14Fixtures.sealed(store: store)
        let installed = try await publisher.publish(projectID: first.projectID, revisionID: first.id, store: store)
        try await store.recordPublished(try await store.publication(projectID: first.projectID, revisionID: first.id).binding)
        let second = try await CreatorS14Fixtures.sealed(store: store, projectID: first.projectID, template: "clock-v2")
        try await store.select(projectID: first.projectID, revisionID: first.id)
        let failing = CreatorPublisher(root: journal, library: library, registry: registry,
            checkpoint: { if $0 == .afterRegistry { throw Probe.interrupted } })
        let ticket = try await failing.prepare(projectID: second.projectID, revisionID: second.id, store: store)
        _ = try await failing.install(ticket)
        do { try await failing.confirm(ticket, verifyInstalled: { _ in }); XCTFail("Fault not injected") } catch Probe.interrupted {}
        // Candidate bytes AND registry match: digest-only checking would allow this.
        let binding = try await registry.bindings()[installed.lastPathComponent]
        XCTAssertEqual(binding?.revisionID, second.id)
        XCTAssertThrowsError(try playback(installed))
        do { try await preflight(installed); XCTFail("Playlist preflight accepted an unconfirmed transaction") } catch {}
        let registryURL = registry.url, publicationRoot = journal
        let page = WebWallpaperPage(projectURL: installed, entryFile: "index.html")
        page.creatorSnapshotLoader = {
            try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registryURL, publicationRoot: publicationRoot)
        }
        let refused = expectation(description: "Unconfirmed page refused before custom-scheme navigation")
        page.onFailure = { _ in refused.fulfill() }; page.onLoaded = { XCTFail("Unconfirmed page ran") }
        page.load()
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertFalse(page.isLoaded); XCTAssertNotEqual(page.webView.url, CreatorWebResources.entryURL)
        page.stop()
        let recovery = CreatorStartupRecovery(store: store, publisher: publisher, registry: registry)
        try await recovery.recover(); try await recovery.recover()
        XCTAssertEqual(try playback(installed).digest, first.bundleDigest)
        try await preflight(installed)
        let project = try await store.project(first.projectID)
        XCTAssertEqual(project.selectedRevisionID, first.id)
        XCTAssertFalse(CreatorPersistence.exists(journal.appendingPathComponent("active")))
    }
    func testLivePublisherCannotBeRecoveredOrPlayedBeforeConfirmation() async throws {
        let revision = try await CreatorS14Fixtures.sealed(store: store)
        let waiting = expectation(description: "candidate awaits confirmation")
        let task = Task {
            try await publisher.publish(projectID: revision.projectID, revisionID: revision.id, store: store) { _ in
                waiting.fulfill(); try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [waiting], timeout: 5)
        let installed = library.appendingPathComponent("ai-" + revision.projectID.uuidString.lowercased())
        XCTAssertThrowsError(try playback(installed))
        do { try await CreatorStartupRecovery(store: store, publisher: publisher, registry: registry).recover(); XCTFail("Recovered live owner") }
        catch CreatorPersistence.Failure.busy {}
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled publish succeeded") } catch is CancellationError {}
        XCTAssertFalse(CreatorPersistence.exists(installed))
        XCTAssertFalse(CreatorPersistence.exists(journal.appendingPathComponent("active")))
    }
    func testSingleByteInEveryInstalledFileRefusesPlaybackAndPlaylistPreflight() async throws {
        let revision = try await CreatorS14Fixtures.sealed(store: store)
        let installed = try await publisher.publish(projectID: revision.projectID, revisionID: revision.id, store: store)
        for name in ["creator.json", "project.json", "index.html", "preview.jpg"] {
            let url = installed.appendingPathComponent(name), original = try Data(contentsOf: url)
            var bytes = original; bytes[bytes.count / 2] ^= 1; try bytes.write(to: url)
            XCTAssertThrowsError(try playback(installed), name)
            do { try await preflight(installed); XCTFail("Tampered file accepted: " + name) } catch {}
            try original.write(to: url)
        }
        try await preflight(installed)
        XCTAssertEqual(try playback(installed).digest, revision.bundleDigest)
    }
    func testUnknownPolicyAndMalformedPublicationJournalFailClosed() async throws {
        let revision = try await CreatorS14Fixtures.sealed(store: store)
        let installed = try await publisher.publish(projectID: revision.projectID, revisionID: revision.id, store: store)
        let original = try Data(contentsOf: registry.url)
        var document = try CreatorRuntimeRegistry.read(at: registry.url)
        let binding = try XCTUnwrap(document.entries[installed.lastPathComponent])
        document.entries[installed.lastPathComponent] = .init(schemaVersion: 1, wallpaperID: binding.wallpaperID,
            projectID: binding.projectID, revisionID: binding.revisionID, bundleVersion: binding.bundleVersion,
            bundleDigest: binding.bundleDigest, runtimePolicy: "generatedOfflineV999", context: binding.context, report: binding.report)
        // Recompute the outer checksum: this must exercise policy validation, not corrupt JSON.
        try CreatorPersistence.write(document, to: registry.url)
        XCTAssertThrowsError(try playback(installed))
        do { try await preflight(installed); XCTFail("Unknown registry accepted") } catch {}
        try original.write(to: registry.url)
        try FileManager.default.createDirectory(at: journal.appendingPathComponent("active"), withIntermediateDirectories: true)
        let log = journal.appendingPathComponent("active/journal.json")
        try Data("broken".utf8).write(to: log)
        do { try await CreatorStartupRecovery(store: store, publisher: publisher, registry: registry).recover(); XCTFail("Lost corrupt recovery evidence") } catch {}
        XCTAssertThrowsError(try playback(installed))
        XCTAssertEqual(try Data(contentsOf: log), Data("broken".utf8))
        XCTAssertEqual(try CreatorDraftStore.read(installed).digest, revision.bundleDigest)
    }
    func testUnavailableLibraryRetainsOldVersionAndRecoverableJournal() async throws {
        let first = try await CreatorS14Fixtures.sealed(store: store)
        let installed = try await publisher.publish(projectID: first.projectID, revisionID: first.id, store: store)
        let second = try await CreatorS14Fixtures.sealed(store: store, projectID: first.projectID, template: "gradient-v2")
        let ticket = try await publisher.prepare(projectID: second.projectID, revisionID: second.id, store: store)
        let detached = root.appendingPathComponent("DetachedLibrary")
        try FileManager.default.moveItem(at: library, to: detached)
        try Data("unavailable mount".utf8).write(to: library)
        do { _ = try await publisher.install(ticket); XCTFail("Unavailable volume accepted") } catch {}
        XCTAssertTrue(CreatorPersistence.exists(journal.appendingPathComponent("active/journal.json")))
        XCTAssertEqual(try CreatorDraftStore.read(detached.appendingPathComponent(installed.lastPathComponent)).digest, first.bundleDigest)
        try FileManager.default.removeItem(at: library); try FileManager.default.moveItem(at: detached, to: library)
        try await CreatorStartupRecovery(store: store, publisher: publisher, registry: registry).recover()
        XCTAssertEqual(try playback(installed).digest, first.bundleDigest)
    }
    func testHeadlessAndPanelRecoveryShareOneOperationAndPreserveValidRevision() async throws {
        let revision = try await CreatorS14Fixtures.sealed(store: store)
        _ = try await publisher.publish(projectID: revision.projectID, revisionID: revision.id, store: store)
        var abandoned: CreatorRevisionStore? = CreatorRevisionStore(root: store.root)
        let ticket = try await abandoned!.beginJob(projectID: revision.projectID)
        abandoned = nil
        let coordinator = CreatorRecoveryCoordinator()
        async let headless = coordinator.recover(store: store, publisher: publisher)
        async let panel = coordinator.recover(store: store, publisher: publisher)
        let (a, b) = try await (headless, panel)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.interruptedJobs.contains(ticket.id))
        let project = try await store.project(revision.projectID)
        XCTAssertEqual(project.selectedRevisionID, revision.id)
    }
    func testBridgeBootstrapWaitsForRecoveryBeforeEnteringEngine() async throws {
        // No native engine, PanelController, window or personal preferences is instantiated.
        let bridge = LayoutSnapshotBridge(noPointer: .init())
        let model = BridgeStore(bridge: bridge)
        model.recoverCreator = { throw Probe.interrupted }
        do { try await model.bootstrapAsync(); XCTFail("Engine bootstrap ran before recovery") } catch Probe.interrupted {}
        // If bootstrap touched the nil engine handle, this test would fail or crash.
        guard case .failed = model.libraryLoadState else { return XCTFail("Failure not surfaced") }
    }
    func testCredentialEchoesInValidMetadataAreRejectedBeforeAnyRevisionOrLogWrite() async throws {
        let c = try await LLMTestContext(tokens: 6144); defer { c.cleanup() }
        let steam = "synthetic-steam-cookie"
        var keyEcho = try CreatorGenerationFixtures.object()
        keyEcho["title"] = LLMTestFixtures.key
        var cookieEcho = try CreatorGenerationFixtures.object()
        cookieEcho["summary"] = "steamLoginSecure=" + steam
        let outputs = [try CreatorGenerationFixtures.text(keyEcho), try CreatorGenerationFixtures.text(cookieEcho), try CreatorGenerationFixtures.output()]
        c.route.replace(try outputs.map { .init(chunks: [try LLMTestFixtures.openAI($0)]) })
        let registry = CreatorRuntimeRegistry(url: c.root.appendingPathComponent("registry.json"))
        let publisher = CreatorPublisher(root: c.root.appendingPathComponent("publication"), library: c.root.appendingPathComponent("Library"), registry: registry)
        let flow = CreatorOrchestrator(store: c.store, generator: CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider), publisher: publisher)
        let result = try await flow.createAndSave(.init(projectID: c.ticket.projectID, profileID: c.profile.id,
            configurationID: c.profile.configurationID, prompt: "星空 " + LLMTestFixtures.key + " sessionid=" + steam, maxRepairs: 2))
        let conversation = try await c.store.conversation(projectID: result.projectID)
        XCTAssertEqual(conversation.turns.last?.attempts.count, 3)
        XCTAssertEqual(conversation.turns.last?.attempts.prefix(2).map { $0.issue?.category }, [.policyViolation, .policyViolation])
        let project = try await c.store.project(result.projectID)
        XCTAssertEqual(project.revisionIDs.count, 2, "Only the safe render draft and sealed revision may persist")
        try CreatorBenchmarkHarness.assertNoSecrets(in: c.root, forbidden: [LLMTestFixtures.key, steam, "private thought"])
        for value in [LLMTestFixtures.key, steam] { XCTAssertFalse(c.diagnostics.lines.joined().contains(value)) }
    }

    func testConcurrentPlaybackReadersShareLeaseWhilePublicationWaits() async throws {
        let revision = try await CreatorS14Fixtures.sealed(store: store)
        let installed = try await publisher.publish(projectID: revision.projectID, revisionID: revision.id, store: store)
        var first = try CreatorPublisher.playbackLease(root: journal)
        var second = try CreatorPublisher.playbackLease(root: journal)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertEqual(try playback(installed).digest, revision.bundleDigest)
        do { _ = try await publisher.prepare(projectID: revision.projectID, revisionID: revision.id, store: store); XCTFail("Writer ignored active snapshots") }
        catch CreatorTemplate.Failure.busy {}
        first = nil; second = nil
        _ = try await publisher.prepare(projectID: revision.projectID, revisionID: revision.id, store: store)
        XCTAssertThrowsError(try playback(installed))
        try await publisher.recover()
        XCTAssertEqual(try playback(installed).digest, revision.bundleDigest)
    }

    func testPolicyAndPendingPublicationErrorsHaveDistinctSafeUserReasons() {
        let policy = CreatorPersistence.Failure.unsupportedVersion.localizedDescription
        let busy = CreatorPersistence.Failure.busy.localizedDescription
        let changed = CreatorPersistence.Failure.staleValidation.localizedDescription
        XCTAssertNotEqual(policy, busy); XCTAssertNotEqual(policy, changed)
        for text in [policy, busy, changed] {
            XCTAssertFalse(text.isEmpty); XCTAssertFalse(text.contains("/Users/"))
            XCTAssertFalse(text.contains("CreatorPersistence.Failure"))
        }
    }

}
