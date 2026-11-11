import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorEngineAcceptanceTests: XCTestCase {
    func testEveryMasterAnimatesUpdatesPausedParametersAndFitsPortraitWithinHostBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for master in try CreatorMasterCatalog.all() {
            let surface = try await CreatorCodeTestFixture.preview(root: root, source: master.source(), script: CreatorHostFoundationTests.clock)
            defer { surface.stop() }
            let before = try await CreatorCodeTestFixture.js(surface, Self.hash) as? Double
            _ = try await CreatorCodeTestFixture.js(surface, "for(let i=0;i<12;i++) __wmStep(34);return true")
            let animated = try await CreatorCodeTestFixture.js(surface, Self.hash) as? Double
            XCTAssertNotEqual(before, animated, master.id)
            try surface.setPaused(true); try await Task.sleep(for: .milliseconds(40))
            let still = try await CreatorCodeTestFixture.js(surface, "const before=WallpaperHost.frame;for(let i=0;i<10;i++)__wmStep(34);return WallpaperHost.frame===before") as? Bool
            XCTAssertEqual(still, true, master.id)
            let parameter = try XCTUnwrap(master.parameters.parameters.first { $0.type == .color })
            let json = try JSONSerialization.data(withJSONObject: [parameter.id: ["value": "#ff2600"]])
            try surface.applyProperties(String(decoding: json, as: UTF8.self)); try await Task.sleep(for: .milliseconds(60))
            let adjusted = try await CreatorCodeTestFixture.js(surface, Self.hash) as? Double
            XCTAssertNotEqual(animated, adjusted, master.id)
            surface.view.setFrameSize(NSSize(width: 180, height: 320)); surface.view.layoutSubtreeIfNeeded()
            // Host suspension deliberately detaches WebKit; a changed container size is
            // delivered when resuming, without waking a hidden wallpaper just for layout.
            try surface.setPaused(false)
            let resizeDeadline = ContinuousClock.now + .seconds(2)
            while (try await CreatorCodeTestFixture.js(surface, "return innerWidth<innerHeight")) as? Bool != true && ContinuousClock.now < resizeDeadline { try await Task.sleep(for: .milliseconds(10)) }
            let size = try await CreatorCodeTestFixture.js(surface, "dispatchEvent(new Event('resize'));const c=document.querySelector('canvas');return [c.width,c.height]") as? [Int]
            XCTAssertLessThan(size?.first ?? 1, size?.last ?? 0, master.id)
            XCTAssertLessThanOrEqual((size?.first ?? 0)*(size?.last ?? 0), 2_073_600)
            let count = try await CreatorCodeTestFixture.js(surface, "const before=WallpaperHost.frame;for(let i=0;i<100;i++)__wmStep(1);return WallpaperHost.frame-before") as? Int
            XCTAssertLessThanOrEqual(count ?? 100, 4, master.id)
            XCTAssertGreaterThan(count ?? 0, 0, master.id)
            XCTAssertNil(surface.view.window)
            let sandbox = try XCTUnwrap(surface.page.creatorCode); surface.stop(); XCTAssertTrue(sandbox.stopped)
        }
    }
    func testBothCoreEnginesUseAllThreeMockProtocolsWithUsageAndNoJSONMode() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            for engine in [CreatorEngine.shaderGLSL, .three3D] {
                let c = try await LLMTestContext(kind: kind, tokens: 8192); defer { c.cleanup() }
                let source = CreatorEngineTests.document(engine).core
                let response = try CreatorGenerationFixtures.response(source, kind: kind)
                let chunks = stride(from: 0, to: response.count, by: 13).map { Data(response[$0..<min(response.count, $0+13)]) }
                c.route.replace([.init(chunks: chunks)])
                var request = CreatorCodeWorkflowTests.request(c); request.engine = engine
                let result = try await CreatorWorkspaceTests.workspace(c).generate(request)
                let snapshot = try await c.store.snapshot(projectID: result.projectID, revisionID: result.sealed.id)
                let doc = try CreatorEngineDocument.read(String(decoding: try XCTUnwrap(snapshot.files["index.html"]), as: UTF8.self))
                XCTAssertEqual(doc?.engine, engine); XCTAssertEqual(doc?.image, source)
                XCTAssertEqual(result.sealed.generation?.usage.inputTokens, 12)
                XCTAssertEqual(result.sealed.generation?.usage.outputTokens, 8)
                XCTAssertEqual(c.route.requests.count, 1)
                let body = String(decoding: try XCTUnwrap(c.route.requests[0].httpBody), as: UTF8.self)
                XCTAssertFalse(body.contains("response_format"))
            }
        }
    }
    func testCoreTextPrefixAndSplitThoughtDoNotCorruptGLSLOrJavaScript() throws {
        for core in [CreatorEngineTests.shader, CreatorEngineTests.three, "/* @param {} */\n"+CreatorEngineTests.shader, "// 云海🌙\n"+CreatorEngineTests.shader] {
            var answer = LLMAnswerBuffer(allowsLeadingThought: true, requiresJSON: false)
            for character in "<think>plan</think>" + core { try answer.append(String(character)) }
            XCTAssertEqual(try answer.finish(usage: .init()).text, core)
            XCTAssertEqual(answer.reasoning, "plan")
        }
    }
    func testBundledArtworkUsesClosedIDsAndCannotReadArbitraryPaths() async throws {
        let pipeline = PanelImagePipeline()
        for master in try CreatorMasterCatalog.all() {
            let image = try await pipeline.image(for: .creatorMaster(id: master.id), maxPixelSize: 160)
            XCTAssertLessThanOrEqual(max(image.cgImage.width, image.cgImage.height), 160)
        }
        for id in ["../catalog", "/Users/fixture", "ink.jpg", "unknown"] {
            do { _ = try await pipeline.image(for: .creatorMaster(id: id), maxPixelSize: 160); XCTFail("Unknown artwork ID read") } catch {}
        }
    }
    func testEngineAfterStartupStillTerminatesAnInfiniteUpdateAtRuntimeDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CreatorEngineTests.three.replacingOccurrences(of: "api.state.mesh.rotation.y+=dt*.3;", with: "if(api.time>.05){while(true){}}")
        let doc = CreatorEngineTests.document(.three3D, source: source)
        let surface = try await CreatorCodeTestFixture.preview(root: root, source: doc.html()); defer { surface.stop() }
        let sandbox = try XCTUnwrap(surface.page.creatorCode), start = ContinuousClock.now
        sandbox.run("__wmValidateFrame();")
        while !sandbox.stopped && start.duration(to: .now) < .seconds(4) { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(sandbox.stopped); XCTAssertEqual(sandbox.failure?.runtimeReason, .timeout)
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
    }
    // Hash actual framebuffer bytes without retaining canvas exports or displaying any windows.
    private static let hash = """
    const c=document.querySelector('canvas');let bytes;const ctx=c.getContext('2d');
    if(ctx)bytes=ctx.getImageData(0,0,c.width,c.height).data;else{const gl=c.getContext('webgl2');bytes=new Uint8Array(c.width*c.height*4);gl.bindFramebuffer(gl.FRAMEBUFFER,null);gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);}
    let hash=2166136261;for(let i=0;i<bytes.length;i+=97)hash=Math.imul(hash^bytes[i],16777619);return hash>>>0;
    """
}
