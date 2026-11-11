import AppKit
import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorPosterTests: XCTestCase {
    func testEveryTemplateProducesBoundedJPEGAndImmutableSealedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["gradient-v2", "stars-v2", "clock-v2"] {
            let store = CreatorRevisionStore(root: root.appendingPathComponent(id))
            let draft = try await CreatorS14Fixtures.draft(store: store, template: id)
            let before = try await store.snapshot(projectID: draft.projectID, revisionID: draft.id)
            let capture = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: store)
            try CreatorBundleManifest.validatePoster(capture.jpeg)
            let sealed = try await store.seal(capture)
            let snapshot = try await store.snapshot(projectID: draft.projectID, revisionID: sealed.id)
            let report = try await store.report(projectID: draft.projectID, revisionID: sealed.id)
            XCTAssertEqual(Set(snapshot.files.keys), ["creator.json", "project.json", "index.html", "preview.jpg"])
            XCTAssertEqual(snapshot.files["preview.jpg"], capture.jpeg)
            XCTAssertEqual(snapshot.files["index.html"], before.files["index.html"])
            XCTAssertEqual(sealed.parentID, draft.id)
            XCTAssertEqual(sealed.renderDigest, draft.renderDigest)
            XCTAssertNotEqual(sealed.bundleDigest, draft.bundleDigest)
            XCTAssertTrue(report.allowsPublication)
            XCTAssertEqual(report.context.testProfile, "template-runtime-v1")
            let original = try await store.snapshot(projectID: draft.projectID, revisionID: draft.id)
            XCTAssertEqual(original.files, before.files)
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.files["project.json"]!) as? [String: Any])
            XCTAssertEqual(manifest["preview"] as? String, "preview.jpg")
        }
    }

    func testActualEncodedPixelDimensionsKeepLandscapeAndPortraitRatios() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (width, height) in [(320, 200), (180, 320), (1280, 720)] {
            let store = CreatorRevisionStore(root: root.appendingPathComponent(UUID().uuidString), context: CreatorS14Fixtures.context(width: width, height: height))
            let draft = try await CreatorS14Fixtures.draft(store: store)
            let captured = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: store)
            XCTAssertLessThanOrEqual(captured.jpeg.count, 512 * 1024)
            XCTAssertLessThanOrEqual(captured.metrics["posterWidth"]!, 1280)
            XCTAssertLessThanOrEqual(captured.metrics["posterHeight"]!, 1280)
            XCTAssertEqual(captured.metrics["posterWidth"]! / captured.metrics["posterHeight"]!, Double(width) / Double(height), accuracy: 0.02)
        }
    }

    func testHeldSnapshotTimesOutAndLateAnswerCannotResumeStoppedPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorRevisionStore(root: root)
        let draft = try await CreatorS14Fixtures.draft(store: store)
        var surface: WebWallpaperPreviewSurface?
        var answer: ((Result<NSImage, Error>) -> Void)?
        let service = CreatorPosterService(timeout: .milliseconds(400), configure: { surface = $0 }, snapshotter: { _, _, completion in answer = completion })
        do { _ = try await service.capture(projectID: draft.projectID, revisionID: draft.id, store: store); XCTFail("Held snapshot succeeded") }
        catch { XCTAssertEqual(error as? CreatorRuntimeFailure, .timeout) }
        XCTAssertNotNil(answer)
        XCTAssertFalse(try XCTUnwrap(surface).page.isLoaded)
        XCTAssertNil(surface?.page.webView.superview)
        answer?(.success(NSImage(size: NSSize(width: 320, height: 180))))
        let project = try await store.project(draft.projectID)
        XCTAssertEqual(project.revisionIDs, [draft.id])
    }

    func testCancellationWhileSnapshotIsHeldStopsAndKeepsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorRevisionStore(root: root)
        let draft = try await CreatorS14Fixtures.draft(store: store)
        let held = expectation(description: "Snapshot request held")
        var surface: WebWallpaperPreviewSurface?
        let service = CreatorPosterService(configure: { surface = $0 }, snapshotter: { _, _, _ in held.fulfill() })
        let task = Task { try await service.capture(projectID: draft.projectID, revisionID: draft.id, store: store) }
        await fulfillment(of: [held], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled snapshot succeeded") }
        catch { XCTAssertEqual(error as? CreatorRuntimeFailure, .cancelled) }
        XCTAssertFalse(surface?.page.isLoaded ?? true)
        let project = try await store.project(draft.projectID)
        XCTAssertEqual(project.revisionIDs, [draft.id])
    }

    func testPageErrorAndEmptyNativeImageNeverProduceEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorRevisionStore(root: root)
        let draft = try await CreatorS14Fixtures.draft(store: store)
        let faulty = CreatorPosterService(configure: { surface in
            surface.page.addUserScript(WKUserScript(source: "addEventListener('DOMContentLoaded',()=>dispatchEvent(new ErrorEvent('error')));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        })
        do { _ = try await faulty.capture(projectID: draft.projectID, revisionID: draft.id, store: store); XCTFail("Error ignored") }
        catch { XCTAssertEqual(error as? CreatorRuntimeFailure, .pageFailed) }
        let blank = CreatorPosterService(snapshotter: { _, _, answer in answer(.success(NSImage(size: NSSize(width: 320, height: 180)))) })
        do { _ = try await blank.capture(projectID: draft.projectID, revisionID: draft.id, store: store); XCTFail("Blank image accepted") }
        catch { XCTAssertEqual(error as? CreatorRuntimeFailure, .invalidCapture) }
    }

    func testUnattachedNativeSnapshotIncludesCanvasAndDOM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorDraftStore(root: root)
        let directory = try await store.create(.init(projectID: UUID(), kind: .clock))
        let surface = try await CreatorPreview.make(directory: directory, store: store).surface
        defer { surface.stop() }
        surface.view.setFrameSize(NSSize(width: 320, height: 180))
        surface.view.layoutSubtreeIfNeeded()
        try await surface.start()
        let deadline = Date().addingTimeInterval(5)
        while !surface.page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(surface.page.isLoaded)
        XCTAssertNil(surface.page.webView.window)
        _ = try await surface.page.webView.callAsyncJavaScript("wallpaperPropertyListener.setPaused(true); wallpaperPropertyListener.applyUserProperties({hue:{value:220},speed:{value:0}}); return document.fonts.ready.then(()=>true);", arguments: [:], in: nil, contentWorld: .page)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = surface.page.webView.bounds
        configuration.snapshotWidth = 320
        configuration.afterScreenUpdates = true
        let image = try await surface.page.webView.takeSnapshot(configuration: configuration)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixels = NSBitmapImageRep(cgImage: cg)
        XCTAssertGreaterThanOrEqual(cg.width, 320)
        XCTAssertEqual(Double(cg.width) / Double(cg.height), 320.0 / 180, accuracy: 0.01)
        let background = try XCTUnwrap(pixels.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(background.alphaComponent, 0.9)
        var bright = 0
        for y in cg.height/4..<cg.height*3/4 { for x in cg.width/8..<cg.width*7/8 {
            if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 { bright += 1 }
        } }
        XCTAssertGreaterThan(bright, 30, "Native snapshot must include the DOM clock over its canvas background")
    }
}
