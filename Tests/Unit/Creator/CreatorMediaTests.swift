import AppKit
import ImageIO
import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorMediaTests: XCTestCase {
    func testReflectionFrameIsFiniteAndResizeSafe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let master = try XCTUnwrap(CreatorMasterCatalog.all().first { $0.id == "reflection" })
        let surface = try await CreatorCodeTestFixture.preview(root: root, source: master.source())
        defer { surface.stop() }
        let probe = try await CreatorCodeTestFixture.js(surface, "return __wmValidateFrame()") as? [String: Int]
        XCTAssertEqual(probe?["nonfinite"], 0)
        let colors = try await CreatorCodeTestFixture.js(surface, "const gl=document.querySelector('canvas').getContext('webgl2'),data=new Uint8Array(4);gl.readPixels(160,120,1,1,gl.RGBA,gl.UNSIGNED_BYTE,data);return Array.from(data)") as? [Int]
        XCTAssertGreaterThan(colors?.prefix(3).max() ?? 0, 12)
        surface.view.setFrameSize(NSSize(width: 960, height: 540))
        try await Task.sleep(for: .milliseconds(100))
        let next = try await CreatorCodeTestFixture.js(surface, "return __wmValidateFrame()") as? [String: Int]
        XCTAssertEqual(next?["nonfinite"], 0)
    }
    func testNativeNormalizationPaletteMaskAndNoMetadataLeak() throws {
        let binding = try CreatorMediaDefaults.binding("lake"), files = try CreatorMediaDefaults.files(binding)
        let prepared = try CreatorMediaAnalysis.image(XCTUnwrap(files[binding.base.path]))
        try prepared.validate()
        XCTAssertEqual(prepared.binding.kind, .image)
        XCTAssertEqual(prepared.binding.palette.count, 5)
        XCTAssertLessThanOrEqual(max(prepared.binding.width, prepared.binding.height), 2048)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(prepared.files[prepared.binding.base.path]! as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertFalse(prepared.binding.promptContext.contains("assets/"))
        XCTAssertThrowsError(try CreatorMediaAnalysis.image(Data("not an image".utf8)))
    }
    func testCancelledTransferStopsAndMediaReplacementCannotUseHotProof() async throws {
        let binding = try CreatorMediaDefaults.binding("night"), assets = try CreatorMediaDefaults.files(binding)
        let master = try XCTUnwrap(CreatorMasterCatalog.all().first { $0.id == "rain" })
        let html = Data(try master.source().utf8), spec = try CreatorCodeOutput.specification(projectID: UUID(), html: html)
        let files = try CreatorBundleManifest.files(for: spec, source: html, assets: assets)
        let manifest = try JSONDecoder().decode(CreatorBundleManifest.self, from: files["creator.json"]!)
        let snapshot = CreatorDraftStore.Snapshot(specification: spec, files: files, digest: CreatorTemplate.digest(files), manifest: manifest)
        let resources = CreatorWebResources(); resources.snapshot = snapshot
        let handler = CreatorMediaResources(resources: resources), view = WKWebView()
        let transfer = MediaTask(request: URLRequest(url: URL(string: binding.base.url)!))
        handler.webView(view, start: transfer); handler.webView(view, stop: transfer)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(transfer.bytes, 0); XCTAssertFalse(transfer.finished)
        var changed = snapshot.files; changed[binding.base.path]![0] ^= 1
        XCTAssertThrowsError(try CreatorParameterUpdate.validate(before: snapshot, after: .init(specification: spec, files: changed, digest: "", manifest: manifest), values: master.parameters.values))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try CreatorBundleManifest.write(files, to: root)
        let file = root.appendingPathComponent(binding.base.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try CreatorBundleManifest.read(root, scopedRevision: true))
    }
    func testRangeHeadAndClosedURLContract() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c), id = try await workspace.createMaster("rain")
        let detail = try await workspace.detail(id), revision = try XCTUnwrap(detail.project.selectedRevisionID)
        let snapshot = try await c.store.snapshot(projectID: id, revisionID: revision)
        let file = try XCTUnwrap(snapshot.manifest?.media?.base)
        var request = URLRequest(url: URL(string: file.url)!)
        request.setValue("bytes=3-21", forHTTPHeaderField: "Range")
        let part = try CreatorMediaResources.response(request, snapshot: snapshot)
        XCTAssertEqual(part.status, 206); XCTAssertEqual(part.range, 3..<22)
        XCTAssertEqual(part.headers["Content-Length"], "19")
        XCTAssertEqual(part.headers["Access-Control-Allow-Origin"], "*")
        request.httpMethod = "HEAD"
        XCTAssertTrue(try CreatorMediaResources.response(request, snapshot: snapshot).range.isEmpty)
        request.httpMethod = "GET"; request.setValue("bytes=0-1,4-5", forHTTPHeaderField: "Range")
        XCTAssertEqual(try CreatorMediaResources.response(request, snapshot: snapshot).status, 416)
        for url in [file.url + "?key=secret", file.url + "#x", "wm-media://other/" + file.path, "wm-media://bundle/assets/../creator.json", "file:///tmp/file", "https://example.invalid/image.jpg"] {
            XCTAssertThrowsError(try CreatorMediaResources.response(URLRequest(url: URL(string: url)!), snapshot: snapshot))
        }
        XCTAssertEqual(CreatorMediaResources.byteRange("bytes=-5", count: 20), 15..<20)
        XCTAssertEqual(CreatorMediaResources.byteRange("bytes=18-999", count: 20), 18..<20)
        XCTAssertEqual(CreatorMediaResources.byteRange("bytes=3-*", count: 20), 3..<20)
        XCTAssertNil(CreatorMediaResources.byteRange("bytes=9999999999999999999999999999-", count: 20))
        XCTAssertNil(CreatorMediaResources.byteRange("bytes=-0", count: 20))
    }
    func testV3AssetTamperAndArchiveTraversalFailClosed() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c), id = try await workspace.createMaster("rays")
        let detail = try await workspace.detail(id), revision = try XCTUnwrap(detail.project.selectedRevisionID)
        let snapshot = try await c.store.snapshot(projectID: id, revisionID: revision)
        XCTAssertEqual(snapshot.bundleVersion, 3); XCTAssertEqual(snapshot.files.count, 7)
        let archive = try CreatorProjectArchive.encode(snapshot)
        XCTAssertEqual(try CreatorProjectArchive.snapshot(archive).files, snapshot.files)
        XCTAssertFalse(String(decoding: archive.prefix(10000), as: UTF8.self).contains("conversation.json"))
        var corrupted = archive; corrupted[corrupted.count-1] ^= 1
        XCTAssertThrowsError(try CreatorProjectArchive.snapshot(corrupted))
        XCTAssertThrowsError(try CreatorProjectArchive.decode(archive + Data([0])))
        let asset = try XCTUnwrap(snapshot.manifest?.media?.base)
        let url = c.store.bundleURL(projectID: id, revisionID: revision).appendingPathComponent(asset.path)
        var bytes = snapshot.files[asset.path]!; bytes[bytes.count/2] ^= 1; try bytes.write(to: url)
        do { _ = try await c.store.report(projectID: id, revisionID: revision); XCTFail("Tampered asset kept old report") } catch {}
        let header = try CreatorPersistence.encode(CreatorProjectArchive.Header(entries: [.init(path: "../escape", bytes: 1, digest: CreatorPersistence.hash(Data([1]))), .init(path: "creator.json", bytes: 1, digest: ""), .init(path: "index.html", bytes: 1, digest: "")]))
        var unsafe = CreatorProjectArchive.magic
        for shift in [24, 16, 8, 0] { unsafe.append(UInt8((UInt32(header.count) >> shift) & 255)) }; unsafe.append(header); unsafe.append(Data([1, 1, 1]))
        XCTAssertThrowsError(try CreatorProjectArchive.decode(unsafe))
    }
    func testImportShareDuplicateHotEditAndModelIterationRetainAssets() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let binding = try CreatorMediaDefaults.binding("forest"), files = try CreatorMediaDefaults.files(binding)
        let id = try await workspace.attachMedia(.init(binding: binding, files: files), projectID: nil)
        let detail = try await workspace.detail(id), base = try XCTUnwrap(detail.project.selectedRevisionID)
        let original = try await c.store.snapshot(projectID: id, revisionID: base)
        var parameters = detail.parameterSchema!.values; parameters["mediaExposure"] = .number(-0.4)
        let updated = try await workspace.edit(project: id, revision: base, parameters: parameters)
        let changed = try await c.store.snapshot(projectID: id, revisionID: updated.id)
        XCTAssertEqual(changed.assets, original.assets)
        let archiveURL = c.root.appendingPathComponent("share.wmpkg")
        try await workspace.exportProject(id, revision: updated.id, to: archiveURL)
        let imported = try await workspace.importProject(archiveURL)
        XCTAssertNotEqual(imported, id)
        let importedDetail = try await workspace.detail(imported)
        XCTAssertEqual(importedDetail.media, binding); XCTAssertTrue(importedDetail.conversation.turns.isEmpty)
        let copied = try await workspace.duplicate(id, title: "Copy")
        let copiedDetail = try await workspace.detail(copied); XCTAssertEqual(copiedDetail.media, binding)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(detail.authorSource!)])])
        var request = CreatorCodeWorkflowTests.request(c); request.projectID = id; request.baseRevisionID = updated.id; request.engine = .hybridMedia
        let result = try await workspace.generate(request)
        let generated = try await c.store.snapshot(projectID: id, revisionID: result.sealed.id)
        XCTAssertEqual(generated.assets, original.assets)
        let body = String(decoding: try XCTUnwrap(c.route.requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("uLumaMask")); XCTAssertFalse(body.contains("data:image")); XCTAssertFalse(body.contains("/Users/"))
        let retained = try await c.store.snapshot(projectID: id, revisionID: base); XCTAssertEqual(retained.files, original.files)
        let installed = try await workspace.publish(project: id, revision: result.sealed.id)
        let publication = try await c.store.publication(projectID: id, revisionID: result.sealed.id)
        XCTAssertEqual(try CreatorBundleManifest.read(installed).digest, publication.snapshot.digest)
    }
    func testVisionThumbnailCodecsRequireExplicitPerModelCapability() throws {
        let media = try CreatorMediaDefaults.binding("lake"), files = try CreatorMediaDefaults.files(media)
        for kind in ProviderProfile.ProtocolKind.allCases {
            var profile = LLMTestFixtures.profile(kind)
            var input = LLMRequest(system: "Compose", messages: [.init(role: .user, content: "Edit the image")], maxOutputTokens: 32)
            input.thumbnailJPEG = files[media.thumbnail.path]
            XCTAssertThrowsError(try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false))
            profile.visionModelIDs = [profile.model]
            let request = try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false)
            let body = String(decoding: request.body, as: UTF8.self)
            XCTAssertTrue(body.contains(input.thumbnailJPEG!.base64EncodedString()))
            XCTAssertFalse(body.contains("wm-media")); XCTAssertFalse(body.contains("assets/"))
            switch kind {
            case .openaiCompatible: XCTAssertTrue(body.contains("image_url"))
            case .anthropicMessages: XCTAssertTrue(body.contains("media_type"))
            case .geminiGenerateContent: XCTAssertTrue(body.contains("inlineData"))
            }
        }
    }
    func testVideoImportRealRangePlaybackPauseAndWebMPoster() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let clip = try await SyntheticVideoFixture.write(.constantRate(name: "media", numerator: 30, denominator: 1, frames: 30), into: c.root)
        let prepared = try await CreatorMediaAnalysis.prepare(clip)
        XCTAssertEqual(prepared.binding.kind, .video)
        let id: UUID
        do { id = try await workspace.attachMedia(prepared, projectID: nil) }
        catch { XCTFail("MOV validation: " + String(decoding: try CreatorPersistence.encode(CreatorRepairIssue.from(error)), as: UTF8.self)); return }
        let detail = try await workspace.detail(id), revision = try XCTUnwrap(detail.project.selectedRevisionID)
        let preview = try await CreatorPreview.make(projectID: id, revisionID: revision, store: c.store), surface = preview.surface
        let mediaHost = CreatorOffscreenMediaWindow(hosting: surface.view)
        defer { mediaHost.contentView = nil; mediaHost.close() }
        defer { surface.stop() }
        surface.view.setFrameSize(NSSize(width: 320, height: 180)); try await surface.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !surface.page.isLoaded && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(surface.page.isLoaded)
        try surface.setPaused(true); try await Task.sleep(for: .milliseconds(60))
        let state = try await CreatorCodeTestFixture.js(surface, "return __wmMediaState()") as? [String: Any]
        XCTAssertEqual(state?["ready"] as? Bool, true); XCTAssertEqual(state?["muted"] as? Bool, true); XCTAssertEqual(state?["paused"] as? Bool, true)
        let time = state?["time"] as? Double
        try await Task.sleep(for: .milliseconds(120))
        let later = try await CreatorCodeTestFixture.js(surface, "return __wmMediaState().time") as? Double
        XCTAssertEqual(time, later)
        XCTAssertGreaterThan(surface.page.creatorMediaResponses[206] ?? 0, 0)
        try surface.setPaused(false); try await Task.sleep(for: .milliseconds(180))
        if let failure = surface.page.creatorCodeFailure { XCTFail(String(decoding: try CreatorPersistence.encode(failure), as: UTF8.self)); return }
        let playing = try await CreatorCodeTestFixture.js(surface, "return __wmMediaState()") as? [String: Any]
        XCTAssertEqual(playing?["paused"] as? Bool, false)
        XCTAssertNotEqual(playing?["time"] as? Double, later)
        let shared = c.root.appendingPathComponent("video.wmpkg")
        try await workspace.exportProject(id, revision: revision, to: shared)
        _ = try await workspace.importProject(shared)
        let webm = c.root.appendingPathComponent("media.webm"); try WebMFixture.vp9.write(to: webm)
        let analyzed = try await CreatorMediaAnalysis.prepare(webm); XCTAssertEqual(analyzed.binding.base.mime, "video/webm")
        do { _ = try await workspace.attachMedia(analyzed, projectID: id) }
        catch { XCTFail("WebM validation: " + String(decoding: try CreatorPersistence.encode(CreatorRepairIssue.from(error)), as: UTF8.self)) }
    }
    func testVideoDraftDecodeState() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let clip = try await SyntheticVideoFixture.write(.constantRate(name: "draft", numerator: 30, denominator: 1, frames: 30), into: c.root)
        let media = try await CreatorMediaAnalysis.prepare(clip)
        let master = try XCTUnwrap(CreatorMasterCatalog.all().first { $0.id == "cinema" })
        var document = try XCTUnwrap(CreatorEngineDocument.read(master.source()))
        document.metadata.media = media.binding
        let source = Data(try document.html().utf8), project = try await c.store.createProject(title: "Video probe")
        let job = try await c.store.beginJob(projectID: project.id)
        _ = try await c.store.stage(CreatorCodeOutput.specification(projectID: project.id, html: source), for: job, source: source, assets: media.files)
        let draft = try await c.store.commit(job, validatingStructure: true)
        let preview = try await CreatorPreview.make(projectID: project.id, revisionID: draft.id, store: c.store)
        let mediaHost = CreatorOffscreenMediaWindow(hosting: preview.surface.view)
        defer { preview.surface.stop(); mediaHost.contentView = nil; mediaHost.close() }
        try await preview.surface.start()
        try await Task.sleep(for: .seconds(1))
        let state = try await CreatorCodeTestFixture.js(preview.surface, "return __wmMediaState()") as? [String: Any]
        XCTAssertEqual(state?["ready"] as? Bool, true, String(describing: state) + " responses=" + String(describing: preview.surface.page.creatorMediaResponses))
    }
    func testMediaNativeParameterDomainsCannotBeRedefined() throws {
        let master = try XCTUnwrap(CreatorMasterCatalog.all().first { $0.id == "rain" })
        var document = try XCTUnwrap(CreatorEngineDocument.read(master.source()))
        document.parameters.values["mediaFill"] = .number(0.5)
        XCTAssertThrowsError(try document.validate())
        document.parameters.values["mediaFill"] = .number(0)
        document.parameters.parameters[0].max = 10000
        XCTAssertThrowsError(try document.validate())
    }

}

@MainActor private final class MediaTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var bytes = 0
    var finished = false
    init(request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { bytes += data.count }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { finished = true }
}

