import XCTest
@testable import WallpaperMachine

final class CreatorDraftTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-draft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testAllTemplatesCreateImmutableCompleteBundlesOutsideLibrary() async throws {
        let store = CreatorDraftStore(root: root.appendingPathComponent("drafts"))
        for kind in CreatorTemplate.Kind.allCases {
            let spec = CreatorTemplate.Specification(projectID: UUID(), kind: kind)
            let directory = try await store.create(spec)
            let first = try await store.snapshot(directory)
            let second = try await store.snapshot(directory, expectedDigest: first.digest)
            XCTAssertEqual(first.digest, second.digest)
            XCTAssertEqual(first.specification, spec)
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: first.files["project.json"]!) as? [String: Any])
            XCTAssertEqual(manifest["type"] as? String, "web")
            XCTAssertNotNil(first.files[manifest["file"] as? String ?? ""])
            do { _ = try await store.create(spec); XCTFail("Overwrote an immutable draft") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    }

    func testChangedBytesAndForgedEntryAreRejected() async throws {
        let store = CreatorDraftStore(root: root)
        let directory = try await store.create(.init(projectID: UUID(), kind: .stars))
        let original = try await store.snapshot(directory)
        try Data("<script>while(true){}</script>".utf8).write(to: directory.appendingPathComponent("index.html"))
        do { _ = try await store.snapshot(directory, expectedDigest: original.digest); XCTFail("Accepted replaced code") } catch {}
        try original.files["index.html"]!.write(to: directory.appendingPathComponent("index.html"))
        try Data(#"{"type":"web","file":"../outside.html"}"#.utf8).write(to: directory.appendingPathComponent("project.json"))
        do { _ = try await store.snapshot(directory); XCTFail("Accepted a traversal entry") } catch {}
    }

    func testNetworkDownloadAllocationAndLogPayloadsNeverReachPreview() async throws {
        let store = CreatorDraftStore(root: root)
        let directory = try await store.create(.init(projectID: UUID(), kind: .gradient))
        let digest = try await store.snapshot(directory).digest
        let payloads = [
            "const a=document.createElement('a');a.href='http://127.0.0.1/download';a.download='x';a.click();",
            "new EventSource('http://127.0.0.1/events');",
            "const retained=[];while(true)retained.push(new Array(1000000).fill(0));",
            "while(true)console.log('unbounded');",
        ]
        for payload in payloads {
            try Data("<script>\(payload)</script>".utf8).write(to: directory.appendingPathComponent("index.html"))
            do {
                _ = try await CreatorPreview.make(directory: directory, store: store, expectedDigest: digest)
                XCTFail("Allowed executable source outside the template format")
            } catch CreatorTemplate.Failure.changedContent {}
        }
    }

    func testSymlinksHardlinksExtraFilesAndForeignDirectoriesAreRejected() async throws {
        let store = CreatorDraftStore(root: root)
        let directory = try await store.create(.init(projectID: UUID(), kind: .clock))
        let page = directory.appendingPathComponent("index.html")
        let outside = root.appendingPathComponent("outside.html")
        try FileManager.default.copyItem(at: page, to: outside)
        try FileManager.default.removeItem(at: page)
        try FileManager.default.createSymbolicLink(at: page, withDestinationURL: outside)
        do { _ = try await store.snapshot(directory); XCTFail("Accepted symlink") } catch {}
        try FileManager.default.removeItem(at: page)
        try FileManager.default.linkItem(at: outside, to: page)
        do { _ = try await store.snapshot(directory); XCTFail("Accepted hardlink") } catch {}
        try FileManager.default.removeItem(at: page)
        try FileManager.default.copyItem(at: outside, to: page)
        try Data("extra".utf8).write(to: directory.appendingPathComponent("payload.js"))
        do { _ = try await store.snapshot(directory); XCTFail("Accepted undeclared executable file") } catch {}
        let foreign = CreatorDraftStore(root: root.appendingPathComponent("different"))
        do { _ = try await foreign.snapshot(directory); XCTFail("Accepted foreign draft") } catch {}
    }

    func testParametersAndCancellationCannotProduceExecutableHalfDrafts() async throws {
        let store = CreatorDraftStore(root: root)
        for speed in [-1.0, 3.0, Double.infinity, Double.nan] {
            do { _ = try await store.create(.init(projectID: UUID(), kind: .gradient, speed: speed)); XCTFail("Accepted invalid parameter") } catch {}
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.create(.init(projectID: UUID(), kind: .gradient))
        }
        do { _ = try await task.value; XCTFail("Created a cancelled draft") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
