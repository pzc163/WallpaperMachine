import XCTest
@testable import WallpaperMachine

final class CreatorStorageBoundaryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testEmptyWorkspaceDoesNotBlockExistingStorageOperations() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Creator"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Creator/.lock"))
        XCTAssertNoThrow(try CreatorStorageBoundary.requirePortable(support: root, storage: root))
    }
    func testEveryCreatorRecordRefusesPartialBackupOrMove() throws {
        for name in ["CreatorSettings.json", "CreatorRuntimeRegistry.json", ".CreatorWorkspacePresent", "Creator/Projects/example", "Creator/Drafts/legacy.json", "Creator/Jobs/job.json", "Library/ai-example"] {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: file)
            XCTAssertThrowsError(try CreatorStorageBoundary.requirePortable(support: root, storage: root), name)
            XCTAssertEqual(try Data(contentsOf: file), Data("kept".utf8))
            try FileManager.default.removeItem(at: file)
        }
    }
    func testPendingMoveOrRestorePreventsFirstCreatorWrite() throws {
        for name in [StorageMoveService.pendingFileName, WallpaperBackupService.pendingDirectoryName, WallpaperBackupService.transactionDirectoryName] {
            let file = root.appendingPathComponent(name); try Data().write(to: file)
            XCTAssertThrowsError(try CreatorStorageBoundary.beginCreatorWrite(support: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".CreatorWorkspacePresent").path))
            try FileManager.default.removeItem(at: file)
        }
        try CreatorStorageBoundary.beginCreatorWrite(support: root)
        XCTAssertThrowsError(try CreatorStorageBoundary.requirePortable(support: root, storage: root))
    }
    func testSharedLeaseFencesConcurrentFirstWrite() throws {
        let lease = try CreatorStorageBoundary.lease(support: root)
        XCTAssertThrowsError(try CreatorStorageBoundary.beginCreatorWrite(support: root))
        withExtendedLifetime(lease) {}
    }
    func testOldBackupContainingAIWallpaperIsRefused() throws {
        let candidate = root.appendingPathComponent("data/Library/ai-example")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CreatorStorageBoundary.requirePortablePackage(root))
    }
    func testBackupExportChecksCreatorBoundaryBeforeCreatingPackage() throws {
        try CreatorStorageBoundary.beginCreatorWrite(support: root)
        let destination = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wmbackup")
        XCTAssertThrowsError(try WallpaperBackupService(supportRoot: root).export(to: destination, includeLibrary: false, preferences: .init(values: [:])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testMovePlanRefusesCreatorEvenBeforeTargetSelection() throws {
        try CreatorStorageBoundary.beginCreatorWrite(support: root)
        XCTAssertThrowsError(try StorageMoveService(support: root).plan(moveTo: root.appendingPathComponent("target")))
    }
}
