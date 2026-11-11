import AppKit
import XCTest
@testable import WallpaperMachine

final class CreatorStorageFormatTests: XCTestCase {
    private var root: URL!
    private enum Probe: Error { case writeFailure }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-format-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ files: [String: Data], at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
    }
    private func poster() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<4 { for x in 0..<8 { bitmap.setColor(.red, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }

    func testDigestSortsRelativePathsAndHashesBytesNotFileStats() {
        let first = ["b/a": Data([1, 2]), "a": Data([3])]
        let reordered = Dictionary(uniqueKeysWithValues: [("a", Data([3])), ("b/a", Data([1, 2]))])
        XCTAssertEqual(CreatorTemplate.digest(first), CreatorTemplate.digest(reordered))
        XCTAssertNotEqual(CreatorTemplate.digest(first), CreatorTemplate.digest(["b/a": Data([2, 1]), "a": Data([3])]))
        XCTAssertNotEqual(CreatorTemplate.digest(["ab": Data("c".utf8)]), CreatorTemplate.digest(["a": Data("bc".utf8)]))
        XCTAssertNotEqual(CreatorTemplate.digest(first), CreatorTemplate.digest(["c/a": Data([1, 2]), "a": Data([3])]))
    }

    func testV2PosterChangesFinalDigestButNotRenderIdentityAndRequiresExactWhitelist() throws {
        let specification = CreatorTemplate.Specification(projectID: UUID(), kind: .stars)
        let directory = root.appendingPathComponent("ai-" + specification.projectID.uuidString.lowercased())
        let draftFiles = try CreatorBundleManifest.files(for: specification)
        try write(draftFiles, at: directory)
        let draft = try CreatorBundleManifest.read(directory)
        XCTAssertEqual(draft.manifest?.packaging, .renderDraft)
        let sealedFiles = try CreatorBundleManifest.files(for: specification, poster: poster())
        try write(sealedFiles, at: directory)
        let sealed = try CreatorBundleManifest.read(directory)
        XCTAssertEqual(Set(sealed.files.keys), ["creator.json", "project.json", "index.html", "preview.jpg"])
        XCTAssertEqual(sealed.manifest?.packaging, .sealed)
        XCTAssertEqual(try sealed.renderDigest, try draft.renderDigest)
        XCTAssertNotEqual(sealed.digest, draft.digest)
        XCTAssertEqual(sealed.manifest?.posterDigest, CreatorPersistence.hash(sealedFiles["preview.jpg"]!))
        // A decoder-valid poster change also needs new metadata and final evidence.
        var changed = sealedFiles["preview.jpg"]!
        changed.append(0)
        try changed.write(to: directory.appendingPathComponent("preview.jpg"))
        XCTAssertThrowsError(try CreatorBundleManifest.read(directory))
        try sealedFiles["preview.jpg"]!.write(to: directory.appendingPathComponent("preview.jpg"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("preview.jpg"))
        XCTAssertThrowsError(try CreatorBundleManifest.read(directory))
        try sealedFiles["preview.jpg"]!.write(to: directory.appendingPathComponent("preview.jpg"))
        try Data([1]).write(to: directory.appendingPathComponent("extra.js"))
        XCTAssertThrowsError(try CreatorBundleManifest.read(directory))
    }

    func testInvalidPosterAndUnknownVersionsNeverBecomeTrustedSnapshots() throws {
        XCTAssertThrowsError(try CreatorBundleManifest.validatePoster(Data()))
        XCTAssertThrowsError(try CreatorBundleManifest.validatePoster(Data("not jpeg".utf8)))
        XCTAssertThrowsError(try CreatorBundleManifest.validatePoster(Data(repeating: 0, count: 512 * 1024 + 1)))
        let spec = CreatorTemplate.Specification(projectID: UUID(), kind: .gradient)
        let directory = root.appendingPathComponent("ai-" + spec.projectID.uuidString.lowercased())
        let files = try CreatorBundleManifest.files(for: spec)
        try write(files, at: directory)
        for field in ["schemaVersion", "bundleVersion", "policyVersion", "sdkVersion"] {
            var metadata = try JSONSerialization.jsonObject(with: files["creator.json"]!) as! [String: Any]
            metadata[field] = 999
            try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("creator.json"))
            XCTAssertThrowsError(try CreatorBundleManifest.read(directory), field)
        }
        var metadata = try JSONSerialization.jsonObject(with: files["creator.json"]!) as! [String: Any]
        metadata["runtimePolicy"] = "generatedOfflineV1"
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("creator.json"))
        XCTAssertThrowsError(try CreatorBundleManifest.read(directory))
    }

    func testAtomicWriteFailureKeepsOldRecordAndRejectsUnknownOrCorruptedRecords() throws {
        let file = root.appendingPathComponent("record.json")
        let old = ["value": 1]
        try CreatorPersistence.write(old, to: file)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try CreatorPersistence.atomicWrite(CreatorPersistence.record(["value": 2]), to: file) { throw Probe.writeFailure })
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try CreatorPersistence.read([String: Int].self, at: file), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["record.json"])
        var object = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        object["schemaVersion"] = 99
        XCTAssertThrowsError(try CreatorPersistence.decode([String: Int].self, from: JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 1
        object["payload"] = ["value": 9]
        XCTAssertThrowsError(try CreatorPersistence.decode([String: Int].self, from: JSONSerialization.data(withJSONObject: object)))
        var padded = before; padded.append(32)
        XCTAssertThrowsError(try CreatorPersistence.decode([String: Int].self, from: padded))
        XCTAssertThrowsError(try CreatorPersistence.write(["tooLarge": String(repeating: "x", count: 256 * 1024)], to: file))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testExclusiveLeasePreventsConcurrentOwnerAndReleasesOnClose() throws {
        let file = root.appendingPathComponent("lock")
        var first: CreatorPersistence.Lease? = try .init(file)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try CreatorPersistence.Lease(file))
        // Failure to acquire must not release the first owner's lock.
        XCTAssertThrowsError(try CreatorPersistence.Lease(file))
        first = nil
        let next = try CreatorPersistence.Lease(file)
        withExtendedLifetime(next) {}
    }

    func testPublisherRejectsDraftAndSealedV2UntilFinalValidationIsImplemented() async throws {
        let spec = CreatorTemplate.Specification(projectID: UUID(), kind: .clock)
        let directory = root.appendingPathComponent("ai-" + spec.projectID.uuidString.lowercased())
        let publisher = CreatorPublisher(root: root.appendingPathComponent("Publication"), library: root.appendingPathComponent("Library"))
        for files in [try CreatorBundleManifest.files(for: spec), try CreatorBundleManifest.files(for: spec, poster: poster())] {
            try write(files, at: directory)
            do { _ = try await publisher.prepare(directory, expectedDigest: CreatorTemplate.digest(files)); XCTFail("Published v2 without final evidence") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    }

    func testOrdinaryImportAlsoRejectsV2DraftAndRenamedCreatorBundles() async throws {
        let spec = CreatorTemplate.Specification(projectID: UUID(), kind: .stars)
        let draft = root.appendingPathComponent("ai-" + spec.projectID.uuidString.lowercased())
        let renamed = root.appendingPathComponent("renamed")
        try write(CreatorBundleManifest.files(for: spec), at: draft)
        try write(CreatorTemplate.files(for: spec), at: renamed)
        let library = root.appendingPathComponent("Library")
        let importer = WallpaperImportService()
        let report = try await importer.importItems([draft, renamed], into: library, duplicates: .replaceChanged, progress: { _ in })
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(draft.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(renamed.lastPathComponent).path))
    }
}
