import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorEngineTests: XCTestCase {
    nonisolated static let shader = "void mainImage(out vec4 c,in vec2 p){vec2 uv=p/iResolution.xy;c=vec4(uv.x*.5,.04,uv.y*.7,1.);}"
    nonisolated static let three = """
    function setupScene(api){const T=api.THREE;const mesh=new T.Mesh(new T.IcosahedronGeometry(1.6,2),new T.MeshPhysicalMaterial({color:0x8060ff,metalness:.65,roughness:.2}));api.scene.add(mesh);return {mesh};}
    function updateScene(api,dt){api.state.mesh.rotation.y+=dt*.3;}
    """
    nonisolated static func document(_ engine: CreatorEngine, source: String? = nil) -> CreatorEngineDocument {
        .init(metadata: .init(engine: engine, title: "Engine test"), parameters: .init(parameters: [], values: [:]), image: source ?? (engine == .shaderGLSL ? shader : three))
    }
    func testCoreContractsRoundTripAndRejectAmbiguityOrUnavailableEngine() throws {
        for engine in [CreatorEngine.shaderGLSL, .three3D] {
            let document = Self.document(engine), html = try document.html()
            XCTAssertEqual(try CreatorEngineDocument.read(html), document)
            try CreatorCodeOutput.validateHTML(Data(html.utf8))
            XCTAssertNotNil(try CreatorLibrary.digest(for: html))
            let fenced = "```" + (engine == .shaderGLSL ? "glsl" : "javascript") + "\n" + document.core + "\n```"
            XCTAssertEqual(try CreatorEngineDocument.parseCore(fenced, engine: engine, reference: document), document)
            XCTAssertThrowsError(try CreatorEngineDocument.parseCore(fenced+"\nextra", engine: engine))
            XCTAssertThrowsError(try CreatorCodeOutput.validateHTML(Data(html.replacingOccurrences(of: "<canvas", with: "<div></div><canvas").utf8)))
        }
        XCTAssertThrowsError(try CreatorEngineDocument.parseCore(Self.shader, engine: .scene25D))
        XCTAssertThrowsError(try CreatorEngineDocument.parseCore("#version 300 es\n"+Self.shader, engine: .shaderGLSL))
        let params = try CreatorHostFoundationTests.schema.json()
        let parsed = try CreatorEngineDocument.parseCore("/* @param " + params + " */\n" + Self.shader, engine: .shaderGLSL)
        XCTAssertEqual(parsed.parameters, CreatorHostFoundationTests.schema)
    }
    func testTwoPassFeedbackAndRealThreeRenderToNativeJPEG() async throws {
        for engine in [CreatorEngine.shaderGLSL, .three3D] {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            var doc = Self.document(engine)
            if engine == .shaderGLSL {
                doc.bufferA = Self.shader
                doc.image = "void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,p/iResolution.xy);}"
            }
            let html = Data(try doc.html().utf8)
            _ = try await c.store.stage(CreatorCodeOutput.specification(projectID: c.ticket.projectID, html: html), for: c.ticket, source: html)
            let draft = try await c.store.commit(c.ticket, validatingStructure: true)
            let capture: CreatorRuntimeCapture
            do { capture = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: c.store) }
            catch { XCTFail("Engine \(engine.rawValue): \(String(decoding: try CreatorPersistence.encode(CreatorRepairIssue.from(error)), as: UTF8.self))"); continue }
            XCTAssertGreaterThan(capture.metrics["distinctColors"] ?? 0, 8)
            let sealed = try await c.store.seal(capture)
            let report = try await c.store.report(projectID: sealed.projectID, revisionID: sealed.id)
            XCTAssertTrue(report.allowsPublication); XCTAssertNotNil(sealed.posterDigest)
        }
    }
    func testShaderRelativeLineDiagnosticRepairsThroughSameBudget() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let bad = "void mainImage(out vec4 c,in vec2 p){\n c=missingIdentifier;\n}"
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(bad)]), .init(chunks: [try LLMTestFixtures.openAI(Self.shader)])])
        var request = CreatorCodeWorkflowTests.request(c, repairs: 1); request.engine = .shaderGLSL
        let result = try await CreatorWorkspaceTests.workspace(c).generate(request)
        let conversation = try await c.store.conversation(projectID: result.projectID)
        let issue = try XCTUnwrap(conversation.turns.last?.attempts.first?.issue)
        XCTAssertEqual(issue.runtimeReason, .shader)
        XCTAssertEqual(issue.shaderDiagnostics?.first?.line, 2); XCTAssertEqual(issue.shaderDiagnostics?.first?.pass, .Image)
        XCTAssertEqual(conversation.turns.last?.requestCount, 2)
        let body = String(decoding: try XCTUnwrap(c.route.requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("shaderDiagnostics")); XCTAssertFalse(body.contains("ERROR:"))
    }
    func testBlankTransparentAndNonfiniteFramesCannotPublish() async throws {
        for source in ["void mainImage(out vec4 c,in vec2 p){c=vec4(0,0,0,1);}",
                       "void mainImage(out vec4 c,in vec2 p){c=vec4(p/iResolution.xy,1,0);}",
                       "void mainImage(out vec4 c,in vec2 p){c=vec4(sqrt(-abs(p.x)));}"] {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            let html = Data(try Self.document(.shaderGLSL, source: source).html().utf8)
            _ = try await c.store.stage(CreatorCodeOutput.specification(projectID: c.ticket.projectID, html: html), for: c.ticket, source: html)
            let draft = try await c.store.commit(c.ticket, validatingStructure: true)
            do { _ = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: c.store); XCTFail("Invalid engine frame accepted") } catch {}
            let report = try await c.store.report(projectID: draft.projectID, revisionID: draft.id)
            XCTAssertFalse(report.allowsPublication)
        }
    }
    func testShaderPauseResizeParametersAndContextRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var doc = Self.document(.shaderGLSL); doc.parameters = CreatorHostFoundationTests.schema
        doc.image = "void mainImage(out vec4 c,in vec2 p){c=vec4(p_tint*(.2+.8*p.x/iResolution.x),1.);}"
        let surface = try await CreatorCodeTestFixture.preview(root: root, source: doc.html(), script: CreatorHostFoundationTests.clock); defer { surface.stop() }
        let before = try await CreatorCodeTestFixture.js(surface, "return __wmValidateFrame()") as? [String: Int]
        XCTAssertGreaterThan(before?["frames"] ?? 0, 0)
        surface.view.setFrameSize(NSSize(width: 180, height: 320))
        _ = try await CreatorCodeTestFixture.js(surface, "dispatchEvent(new Event('resize'));return __wmValidateFrame()")
        let size = try await CreatorCodeTestFixture.js(surface, "return [document.querySelector('canvas').width,document.querySelector('canvas').height]") as? [Int]
        XCTAssertLessThan(size?.first ?? 1, size?.last ?? 0)
        try surface.applyProperties(##"{"tint":{"value":"#00ff00"}}"##)
        try surface.setPaused(true); try await Task.sleep(for: .milliseconds(60))
        let paused = try await CreatorCodeTestFixture.js(surface, "const f=WallpaperHost.frame;for(let i=0;i<5;i++)__wmStep(34);return f===WallpaperHost.frame") as? Bool
        XCTAssertEqual(paused, true)
        _ = try await CreatorCodeTestFixture.js(surface, "window.__lost=document.querySelector('canvas').getContext('webgl2').getExtension('WEBGL_lose_context');__lost.loseContext();return true")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await CreatorCodeTestFixture.js(surface, "__lost.restoreContext();return true")
        try await Task.sleep(for: .milliseconds(250))
        let restored = try await CreatorCodeTestFixture.js(surface, "return __wmValidateFrame()") as? [String: Int]
        XCTAssertEqual(restored?["nonfinite"], 0)
    }
}
