import XCTest
@testable import WallpaperMachine

final class CreatorPublisherTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("managed/Library") }
    private var publication: URL { root.appendingPathComponent("publication") }
    private enum ProbeFailure: Error { case failed }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-publish-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func draft(_ id: UUID, kind: CreatorTemplate.Kind) async throws -> (URL, CreatorDraftStore.Snapshot) {
        let store = CreatorDraftStore(root: root.appendingPathComponent(UUID().uuidString))
        let directory = try await store.create(.init(projectID: id, kind: kind))
        return (directory, try await store.snapshot(directory))
    }

    func testRealImportPreservesSourceAndStableIDAndRefusesStaleDigest() async throws {
        let (directory, snapshot) = try await draft(UUID(), kind: .stars)
        let publisher = CreatorPublisher(root: publication, library: library)
        let destination = try await publisher.publish(directory, expectedDigest: snapshot.digest) { installed in
            XCTAssertEqual(try CreatorDraftStore.read(installed).digest, snapshot.digest)
        }
        XCTAssertEqual(destination.lastPathComponent, snapshot.wallpaperID)
        XCTAssertEqual(try CreatorDraftStore.read(directory).digest, snapshot.digest)
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, snapshot.digest)
        do { _ = try await publisher.prepare(directory, expectedDigest: String(repeating: "0", count: 64)); XCTFail("Accepted stale test result") } catch {}
    }

    func testFailedVerificationRestoresPreviousVersion() async throws {
        let id = UUID()
        let (original, before) = try await draft(id, kind: .gradient)
        let (candidate, after) = try await draft(id, kind: .clock)
        let publisher = CreatorPublisher(root: publication, library: library)
        let destination = try await publisher.publish(original, expectedDigest: before.digest) { _ in }
        do {
            _ = try await publisher.publish(candidate, expectedDigest: after.digest) { _ in throw ProbeFailure.failed }
            XCTFail("Reported a failed verification as successful")
        } catch ProbeFailure.failed {}
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, before.digest)
        XCTAssertEqual(try CreatorDraftStore.read(candidate).digest, after.digest)
        try await publisher.recover()
    }

    func testRestartAfterInstallRollsBackAndRecoveryIsIdempotent() async throws {
        let id = UUID()
        let (original, before) = try await draft(id, kind: .gradient)
        let (candidate, after) = try await draft(id, kind: .stars)
        let publisher = CreatorPublisher(root: publication, library: library)
        let destination = try await publisher.publish(original, expectedDigest: before.digest) { _ in }
        let ticket = try await publisher.prepare(candidate, expectedDigest: after.digest)
        _ = try await publisher.install(ticket)
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, after.digest)
        // A new owner sees only disk state, as after process termination before confirmation.
        let restarted = CreatorPublisher(root: publication, library: library)
        try await restarted.recover()
        try await restarted.recover()
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, before.digest)
    }

    func testUnconfirmedFirstImportIsRemovedButUnrelatedWallpaperSurvives() async throws {
        let (directory, snapshot) = try await draft(UUID(), kind: .clock)
        let publisher = CreatorPublisher(root: publication, library: library)
        let ticket = try await publisher.prepare(directory, expectedDigest: snapshot.digest)
        let installed = try await publisher.install(ticket)
        let unrelated = library.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: unrelated.appendingPathComponent("user-file"))
        try await CreatorPublisher(root: publication, library: library).recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(try String(contentsOf: unrelated.appendingPathComponent("user-file"), encoding: .utf8), "keep")
    }

    func testRecoveryCoversImportBeforeJournalAdvances() async throws {
        let id = UUID()
        let (original, before) = try await draft(id, kind: .gradient)
        let (candidate, after) = try await draft(id, kind: .stars)
        let publisher = CreatorPublisher(root: publication, library: library)
        let destination = try await publisher.publish(original, expectedDigest: before.digest) { _ in }
        _ = try await publisher.prepare(candidate, expectedDigest: after.digest)
        // Simulate termination after the real import, before the installed phase is recorded.
        let staged = publication.appendingPathComponent("active/candidate/" + after.wallpaperID)
        let report = try await WallpaperImportService().importItems([staged], into: library, duplicates: .replaceChanged, progress: { _ in })
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, after.digest)
        try await CreatorPublisher(root: publication, library: library).recover()
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, before.digest)
    }

    func testCancellationDuringVerificationStillRestoresPreviousVersion() async throws {
        let id = UUID()
        let (original, before) = try await draft(id, kind: .gradient)
        let (candidate, after) = try await draft(id, kind: .clock)
        let publisher = CreatorPublisher(root: publication, library: library)
        let destination = try await publisher.publish(original, expectedDigest: before.digest) { _ in }
        let verifying = expectation(description: "Candidate installed, verification pending")
        let task = Task {
            try await publisher.publish(candidate, expectedDigest: after.digest) { _ in
                verifying.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [verifying], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Confirmed cancelled publication") } catch is CancellationError {}
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, before.digest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publication.appendingPathComponent("active").path))
    }

    func testChangesBetweenPreparationAndImportAreNotOverwritten() async throws {
        let id = UUID()
        let (original, before) = try await draft(id, kind: .gradient)
        let (candidate, after) = try await draft(id, kind: .clock)
        let publisher = CreatorPublisher(root: publication, library: library)
        let destination = try await publisher.publish(original, expectedDigest: before.digest) { _ in }
        let ticket = try await publisher.prepare(candidate, expectedDigest: after.digest)
        let file = destination.appendingPathComponent("index.html")
        try Data("external edit".utf8).write(to: file)
        do { _ = try await publisher.install(ticket); XCTFail("Replaced newly edited content") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external edit")
    }

    func testRecoveryDoesNotOverwriteExternalEditsAndBlocksAnotherPublication() async throws {
        let (directory, snapshot) = try await draft(UUID(), kind: .stars)
        let publisher = CreatorPublisher(root: publication, library: library)
        let ticket = try await publisher.prepare(directory, expectedDigest: snapshot.digest)
        do { _ = try await publisher.prepare(directory, expectedDigest: snapshot.digest); XCTFail("Allowed conflicting transaction") } catch {}
        let installed = try await publisher.install(ticket)
        let file = installed.appendingPathComponent("index.html")
        try Data("user-edited".utf8).write(to: file)
        do { try await publisher.recover(); XCTFail("Overwrote externally edited content") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user-edited")
    }
}
