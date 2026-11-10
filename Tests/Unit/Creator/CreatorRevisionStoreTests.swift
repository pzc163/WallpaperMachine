import XCTest
@testable import WallpaperMachine

final class CreatorRevisionStoreTests: XCTestCase {
    private var root: URL!
    private let context = ValidationReport.Context(policyVersion: 1, sdkVersion: 1, hostVersion: "test-host", testProfile: "template-structure-v1", width: 960, height: 540)
    private enum Probe: Error { case interrupted }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-revisions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func store(_ checkpoint: @escaping @Sendable (CreatorRevisionStore.Checkpoint) throws -> Void = { _ in }) -> CreatorRevisionStore {
        CreatorRevisionStore(root: root.appendingPathComponent("Creator"), context: context, checkpoint: checkpoint)
    }
    private func rejected<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("Accepted invalid state", file: file, line: line) } catch {}
    }
    private func add(_ store: CreatorRevisionStore, project: CreatorProject, parent: UUID? = nil,
                     kind: CreatorTemplate.Kind = .stars, legacy: Bool = false) async throws -> CreatorRevision {
        let job = try await store.beginJob(projectID: project.id, baseRevisionID: parent)
        _ = try await store.stage(.init(projectID: project.id, kind: kind), for: job, summary: "local fixture", legacy: legacy)
        return try await store.commit(job)
    }

    func testDerivationKeepsOldBytesAndReportAndAllowsExplicitRollback() async throws {
        let store = store()
        let project = try await store.createProject(title: "History")
        let first = try await add(store, project: project)
        let report = try await store.validate(projectID: project.id, revisionID: first.id)
        let original = try Data(contentsOf: store.revisionURL(projectID: project.id, revisionID: first.id).appendingPathComponent("revision.json"))
        let firstFiles = try await store.snapshot(projectID: project.id, revisionID: first.id).files
        let second = try await add(store, project: project, parent: first.id, kind: .clock)
        XCTAssertEqual(second.parentID, first.id)
        XCTAssertNotEqual(second.bundleDigest, first.bundleDigest)
        let pending = try await store.project(project.id)
        XCTAssertEqual(pending.revisionIDs, [first.id, second.id])
        XCTAssertEqual(pending.latestRevisionID, second.id)
        XCTAssertEqual(pending.selectedRevisionID, first.id)
        await rejected { try await store.snapshot(projectID: project.id, revisionID: second.id) }
        _ = try await store.validate(projectID: project.id, revisionID: second.id)
        try await store.select(projectID: project.id, revisionID: first.id)
        let recovered = self.store()
        _ = try await recovered.recover()
        let reopened = try await recovered.project(project.id)
        XCTAssertEqual(reopened.selectedRevisionID, first.id)
        XCTAssertNil(reopened.publishedWallpaperID)
        let old = try await recovered.snapshot(projectID: project.id, revisionID: first.id)
        let oldReport = try await recovered.report(projectID: project.id, revisionID: first.id)
        XCTAssertEqual(old.files, firstFiles)
        XCTAssertEqual(oldReport, report)
        XCTAssertEqual(try Data(contentsOf: store.revisionURL(projectID: project.id, revisionID: first.id).appendingPathComponent("revision.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    }

    func testEveryBundleByteChangeInvalidatesReportEvenWithSameSizeAndMtime() async throws {
        let store = store()
        let project = try await store.createProject(title: "Tampering")
        let revision = try await add(store, project: project)
        _ = try await store.validate(projectID: project.id, revisionID: revision.id)
        let bundle = store.bundleURL(projectID: project.id, revisionID: revision.id)
        for name in ["creator.json", "project.json", "index.html"] {
            let file = bundle.appendingPathComponent(name)
            let original = try Data(contentsOf: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            var changed = original
            changed[changed.startIndex + changed.count / 2] ^= 1
            try changed.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
            await rejected { try await store.report(projectID: project.id, revisionID: revision.id) }
            try original.write(to: file)
            _ = try await store.report(projectID: project.id, revisionID: revision.id)
        }
        try Data("unexpected".utf8).write(to: bundle.appendingPathComponent("other.js"))
        await rejected { try await store.snapshot(projectID: project.id, revisionID: revision.id) }
    }

    func testMetadataAndHostChangesInvalidateReportsWithoutRewritingRevisions() async throws {
        let store = store()
        let project = try await store.createProject(title: "Bindings")
        let revision = try await add(store, project: project)
        _ = try await store.validate(projectID: project.id, revisionID: revision.id)
        let url = store.revisionURL(projectID: project.id, revisionID: revision.id).appendingPathComponent("revision.json")
        let original = try Data(contentsOf: url)
        // Recompute the storage checksum, proving the report also binds immutable metadata bytes.
        var object = try JSONSerialization.jsonObject(with: CreatorPersistence.encode(revision)) as! [String: Any]
        object["promptSummary"] = "changed provenance"
        let edited = try JSONDecoder().decode(CreatorRevision.self, from: JSONSerialization.data(withJSONObject: object))
        try CreatorPersistence.write(edited, to: url)
        await rejected { try await store.report(projectID: project.id, revisionID: revision.id) }
        try original.write(to: url)
        for changed in [
            ValidationReport.Context(policyVersion: 1, sdkVersion: 1, hostVersion: "another-host", testProfile: "template-structure-v1", width: 960, height: 540),
            ValidationReport.Context(policyVersion: 1, sdkVersion: 1, hostVersion: "test-host", testProfile: "template-structure-v1", width: 320, height: 180),
            ValidationReport.Context(policyVersion: 2, sdkVersion: 1, hostVersion: "test-host", testProfile: "template-structure-v1", width: 960, height: 540)
        ] {
            let reopened = CreatorRevisionStore(root: store.root, context: changed)
            await rejected { try await reopened.report(projectID: project.id, revisionID: revision.id) }
        }
        try await store.renameProject(project.id, title: "Renamed")
        await rejected { try await store.report(projectID: project.id, revisionID: revision.id) }
        _ = try await store.validate(projectID: project.id, revisionID: revision.id)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReportTamperingAndMissingEvidenceFailClosed() async throws {
        let store = store()
        let project = try await store.createProject(title: "Evidence")
        let revision = try await add(store, project: project)
        let report = try await store.validate(projectID: project.id, revisionID: revision.id)
        XCTAssertTrue(report.allowsPreview)
        XCTAssertEqual(report.results["runtime"], .notChecked)
        XCTAssertEqual(report.results["posterCapture"], .notChecked)
        let url = store.revisionURL(projectID: project.id, revisionID: revision.id).appendingPathComponent("validation.json")
        var bytes = try Data(contentsOf: url)
        bytes.append(32)
        try bytes.write(to: url)
        await rejected { try await store.snapshot(projectID: project.id, revisionID: revision.id) }
        try FileManager.default.removeItem(at: url)
        await rejected { try await store.select(projectID: project.id, revisionID: revision.id) }
    }

    func testCancellationCleansPartialAndStagedFilesAndFencesLateCallbacks() async throws {
        let store = store()
        let project = try await store.createProject(title: "Cancellation")
        let first = try await store.beginJob(projectID: project.id)
        try await store.savePartial(Data("partial".utf8), for: first)
        _ = try await store.stage(.init(projectID: project.id, kind: .stars), for: first)
        let second = try await store.beginJob(projectID: project.id)
        let oldJob = try await store.job(first.id)
        XCTAssertEqual(oldJob.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.jobURL(first.id).appendingPathComponent("candidate").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.jobURL(first.id).appendingPathComponent("partial.bin").path))
        await rejected { try await store.commit(first) }
        await rejected { try await store.savePartial(Data(), for: first) }
        let forged = GenerationJob.Ticket(id: second.id, projectID: second.projectID, cancellationToken: UUID())
        await rejected { try await store.cancel(forged) }
        try await store.cancel(second)
        try await store.cancel(second)
        let state = try await store.project(project.id)
        XCTAssertNil(state.activeJobID)
        XCTAssertTrue(state.revisionIDs.isEmpty)
    }

    func testRequestAndPartialBudgetsAndCancelledTaskDoNotCreateRevision() async throws {
        let store = store()
        let project = try await store.createProject(title: "Budgets")
        await rejected { try await store.beginJob(projectID: project.id, requestBudget: 0) }
        await rejected { try await store.beginJob(projectID: project.id, tokenBudget: 100001) }
        let job = try await store.beginJob(projectID: project.id, requestBudget: 1)
        try await store.recordAttempt(job)
        await rejected { try await store.recordAttempt(job) }
        await rejected { try await store.savePartial(Data(repeating: 0, count: 16385), for: job) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.stage(.init(projectID: project.id, kind: .gradient), for: job)
        }
        await rejected { try await task.value }
        try await store.cancel(job)
        let state = try await store.project(project.id)
        XCTAssertTrue(state.revisionIDs.isEmpty)
    }

    func testRestartCleansInterruptedJobsAndRecoversLastValidSelection() async throws {
        var owner: CreatorRevisionStore? = store()
        let project = try await owner!.createProject(title: "Restart")
        let valid = try await add(owner!, project: project)
        _ = try await owner!.validate(projectID: project.id, revisionID: valid.id)
        let job = try await owner!.beginJob(projectID: project.id, baseRevisionID: valid.id)
        try await owner!.savePartial(Data("unfinished".utf8), for: job)
        _ = try await owner!.stage(.init(projectID: project.id, kind: .clock), for: job)
        let restarted = store()
        let live = try await restarted.recover()
        XCTAssertEqual(live.liveJobs, [job.id])
        owner = nil
        let result = try await restarted.recover()
        XCTAssertEqual(result.interruptedJobs, [job.id])
        let jobState = try await restarted.job(job.id)
        let state = try await restarted.project(project.id)
        XCTAssertEqual(jobState.state, .interrupted)
        XCTAssertEqual(state.revisionIDs, [valid.id])
        XCTAssertEqual(state.selectedRevisionID, valid.id)
        XCTAssertNil(state.activeJobID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.jobURL(job.id).appendingPathComponent("candidate").path))
        let again = try await restarted.recover()
        XCTAssertEqual(again, .init())
    }

    func testCrashBeforeAndAfterProjectCommitRecoversAtAtomicBoundary() async throws {
        for boundary in [CreatorRevisionStore.Checkpoint.afterRevisionMove, .afterProjectCommit] {
            let folder = root.appendingPathComponent(UUID().uuidString)
            var owner: CreatorRevisionStore? = CreatorRevisionStore(root: folder, context: context, checkpoint: { point in
                if point == boundary { throw Probe.interrupted }
            })
            let project = try await owner!.createProject(title: "Commit boundary")
            let job = try await owner!.beginJob(projectID: project.id)
            let revision = try await owner!.stage(.init(projectID: project.id, kind: .gradient), for: job)
            await rejected { try await owner!.commit(job) }
            owner = nil
            let restarted = CreatorRevisionStore(root: folder, context: context)
            let recovery = try await restarted.recover()
            let state = try await restarted.project(project.id)
            let jobState = try await restarted.job(job.id)
            if boundary == .afterRevisionMove {
                XCTAssertEqual(recovery.interruptedJobs, [job.id])
                XCTAssertTrue(state.revisionIDs.isEmpty)
                XCTAssertEqual(jobState.state, .interrupted)
                XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.revisionURL(projectID: project.id, revisionID: revision.id).path))
            } else {
                XCTAssertEqual(recovery.completedJobs, [job.id])
                XCTAssertEqual(state.revisionIDs, [revision.id])
                XCTAssertEqual(jobState.state, .completed)
                XCTAssertNil(state.selectedRevisionID, "Saving does not fabricate validation")
            }
        }
    }

    func testRecoveryFallsBackFromCorruptLatestAndPreservesDamagedBytes() async throws {
        let store = store()
        let project = try await store.createProject(title: "Fallback")
        let first = try await add(store, project: project)
        _ = try await store.validate(projectID: project.id, revisionID: first.id)
        let second = try await add(store, project: project, parent: first.id, kind: .clock)
        _ = try await store.validate(projectID: project.id, revisionID: second.id)
        let file = store.bundleURL(projectID: project.id, revisionID: second.id).appendingPathComponent("index.html")
        try Data("external edit".utf8).write(to: file)
        _ = try await store.recover()
        let state = try await store.project(project.id)
        XCTAssertEqual(state.latestRevisionID, first.id)
        XCTAssertEqual(state.lastValidatedRevisionID, first.id)
        XCTAssertEqual(state.selectedRevisionID, first.id)
        XCTAssertEqual(state.revisionIDs, [first.id, second.id])
        XCTAssertEqual(try Data(contentsOf: file), Data("external edit".utf8))
    }

    func testForeignParentAndSymlinkedStoresAreRejected() async throws {
        let store = store()
        let first = try await store.createProject(title: "One")
        let second = try await store.createProject(title: "Two")
        let revision = try await add(store, project: first)
        await rejected { try await store.beginJob(projectID: second.id, baseRevisionID: revision.id) }
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.root)
        let aliased = CreatorRevisionStore(root: link, context: context)
        await rejected { try await aliased.project(first.id) }
        let metadata = store.projectURL(second.id).appendingPathComponent("project-meta.json")
        let outside = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: metadata, to: outside)
        try FileManager.default.linkItem(at: outside, to: metadata)
        await rejected { try await store.project(second.id) }
    }

    func testLegacyImportAndMigrationDoNotChangeFrozenDigestOrSource() async throws {
        let drafts = CreatorDraftStore(root: root.appendingPathComponent("Drafts"))
        let directory = try await drafts.create(.init(projectID: UUID(), kind: .gradient))
        let legacy = try await drafts.snapshot(directory)
        let store = store()
        let first = try await store.importLegacy(directory, title: "Imported")
        _ = try await store.validate(projectID: first.projectID, revisionID: first.id)
        let copy = try await store.snapshot(projectID: first.projectID, revisionID: first.id)
        XCTAssertEqual(first.bundleVersion, 1)
        XCTAssertEqual(copy.files, legacy.files)
        XCTAssertEqual(first.bundleDigest, legacy.digest)
        let project = try await store.project(first.projectID)
        let upgraded = try await add(store, project: project, parent: first.id)
        XCTAssertEqual(upgraded.bundleVersion, 2)
        let source = try await drafts.snapshot(directory)
        XCTAssertEqual(source.files, legacy.files)
        let old = try await store.report(projectID: first.projectID, revisionID: first.id)
        XCTAssertEqual(old.bundleDigest, legacy.digest)
    }

    func testInterruptedAtomicReportWriteKeepsPreviousEvidenceAndRecovers() async throws {
        let store = store()
        let project = try await store.createProject(title: "Atomic recovery")
        let revision = try await add(store, project: project)
        let original = try await store.validate(projectID: project.id, revisionID: revision.id)
        let folder = store.revisionURL(projectID: project.id, revisionID: revision.id)
        let pending = folder.appendingPathComponent(".pending-" + UUID().uuidString.lowercased())
        try Data("unfinished report".utf8).write(to: pending)
        await rejected { try await store.snapshot(projectID: project.id, revisionID: revision.id) }
        let result = try await store.recover()
        XCTAssertEqual(result.discardedAtomicWrites, 1)
        let report = try await store.report(projectID: project.id, revisionID: revision.id)
        XCTAssertEqual(report, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testRecoveryPreservesCorruptJournalAndDoesNotBlockHealthyProject() async throws {
        var owner: CreatorRevisionStore? = store()
        let project = try await owner!.createProject(title: "Corrupt job")
        let job = try await owner!.beginJob(projectID: project.id)
        let file = owner!.jobURL(job.id).appendingPathComponent("job.json")
        try Data("corrupted journal".utf8).write(to: file)
        owner = nil
        let reopened = store()
        let result = try await reopened.recover()
        XCTAssertEqual(result.invalidJobs, [job.id])
        XCTAssertEqual(try Data(contentsOf: file), Data("corrupted journal".utf8))
        let state = try await reopened.project(project.id)
        XCTAssertNil(state.activeJobID)
        let next = try await reopened.beginJob(projectID: project.id)
        try await reopened.cancel(next)
    }

    func testCancelledCommitBeforeIndexWriteCanStillCleanUp() async throws {
        let store = self.store { point in
            if point == .afterRevisionMove { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let project = try await store.createProject(title: "Cancellation boundary")
        let job = try await store.beginJob(projectID: project.id)
        let revision = try await store.stage(.init(projectID: project.id, kind: .clock), for: job)
        let task = Task {
            do { _ = try await store.commit(job); XCTFail("Committed a cancelled task") } catch is CancellationError {}
            // Cleanup itself is cancellation-independent.
            try await store.cancel(job)
        }
        try await task.value
        let state = try await store.project(project.id)
        XCTAssertTrue(state.revisionIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.revisionURL(projectID: project.id, revisionID: revision.id).path))
    }

    func testUnavailableStorageDoesNotCreateFallbackWorkspace() async throws {
        let missing = root.appendingPathComponent("disconnected/Creator")
        let store = CreatorRevisionStore(root: missing, context: context, checkStorage: { throw Probe.interrupted })
        await rejected { try await store.createProject(title: "Unavailable") }
        await rejected { try await store.recover() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
