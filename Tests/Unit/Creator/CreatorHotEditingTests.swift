import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorHotEditingTests: XCTestCase {
    func testParameterSaveReusesSupervisedPageAndPreservesOldRevision() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let id = try await workspace.createMaster("ink"), detail = try await workspace.detail(id)
        let base = try XCTUnwrap(detail.project.selectedRevisionID), schema = try XCTUnwrap(detail.parameterSchema)
        let original = try await c.store.snapshot(projectID: id, revisionID: base)
        let preview = CreatorEmbeddedPreview(); defer { preview.close() }
        try await preview.open(project: id, revision: base, store: c.store)
        let deadline = ContinuousClock.now + .seconds(5)
        while preview.state == .loading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(preview.state, .ready)
        let view = try XCTUnwrap(preview.view)
        var values = schema.values; values["violet"] = .choice("#4060ff")
        try schema.validate(values)
        try preview.properties(values)
        let capturedValues = values
        let updated = try await workspace.edit(project: id, revision: base, parameters: values, hotCapture: { project, target, store in
            try await preview.captureParameters(project: project, base: base, target: target, store: store, values: capturedValues)
        })
        XCTAssertTrue(preview.view === view, "Hot save must not reload or replace the page")
        let report = try await c.store.report(projectID: id, revisionID: updated.id)
        XCTAssertTrue(report.allowsPublication); XCTAssertNotEqual(updated.bundleDigest, original.digest)
        let retained = try await c.store.snapshot(projectID: id, revisionID: base)
        XCTAssertEqual(retained.files, original.files); XCTAssertTrue(c.route.requests.isEmpty)
    }
    func testHotProofRejectsSourceEditsEvenIfParameterMetadataIsValid() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c), id = try await workspace.createMaster("ink")
        let detail = try await workspace.detail(id), revision = try XCTUnwrap(detail.project.selectedRevisionID)
        let original = try await c.store.snapshot(projectID: id, revisionID: revision)
        var changed = original.files
        changed["index.html"]!.append(Data("<!-- source change -->".utf8))
        let candidate = CreatorDraftStore.Snapshot(specification: original.specification, files: changed, digest: "", manifest: original.manifest)
        XCTAssertThrowsError(try CreatorParameterUpdate.validate(before: original, after: candidate, values: detail.parameterSchema!.values))
    }
    func testSourceEditingRevalidatesAndFailedShaderKeepsLastGoodSelection() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c), id = try await workspace.createMaster("ink")
        let detail = try await workspace.detail(id), base = try XCTUnwrap(detail.project.selectedRevisionID)
        let original = try await c.store.snapshot(projectID: id, revisionID: base)
        let updated = try await workspace.editSource(project: id, revision: base, source: CreatorEngineTests.shader)
        XCTAssertNotEqual(updated.id, base)
        do { _ = try await workspace.editSource(project: id, revision: updated.id, source: "void mainImage(out vec4 c,in vec2 p){c=missingName;}"); XCTFail("Invalid shader accepted") } catch {}
        let after = try await c.store.project(id)
        XCTAssertEqual(after.selectedRevisionID, updated.id)
        let retained = try await c.store.snapshot(projectID: id, revisionID: base)
        XCTAssertEqual(retained.digest, original.digest); XCTAssertTrue(c.route.requests.isEmpty)
    }
    func testFloatFeedbackAndAllocationFailureFallbackRenderRealPixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try CreatorEngineDocument.parseCore(CreatorEngineTests.shader, engine: .shaderGLSL)
        document.bufferA = CreatorEngineTests.shader
        let scripts = ["", "const old=WebGL2RenderingContext.prototype.getExtension;WebGL2RenderingContext.prototype.getExtension=function(n){return n==='EXT_color_buffer_float'?null:old.call(this,n)};",
            "const old=WebGL2RenderingContext.prototype.checkFramebufferStatus;let checks=0;WebGL2RenderingContext.prototype.checkFramebufferStatus=function(t){return ++checks%2?this.FRAMEBUFFER_INCOMPLETE_ATTACHMENT:old.call(this,t)};"]
        for (index, script) in scripts.enumerated() {
            let surface = try await CreatorCodeTestFixture.preview(root: root, source: document.html(), script: script)
            defer { surface.stop() }
            let probe = try await CreatorCodeTestFixture.js(surface, "return __wmValidateFrame()") as? [String: Int]
            XCTAssertEqual(probe?["nonfinite"], 0)
            XCTAssertEqual(probe?["feedbackBits"], index == 0 ? 16 : 8)
            let color = try await CreatorCodeTestFixture.js(surface, "const g=document.querySelector('canvas').getContext('webgl2'),p=new Uint8Array(4);g.readPixels(100,60,1,1,g.RGBA,g.UNSIGNED_BYTE,p);return Array.from(p)") as? [Int]
            XCTAssertGreaterThan((color ?? []).prefix(3).max() ?? 0, 12)
        }
        XCTAssertEqual(CreatorPersistence.hash(try CreatorLibrary.bytes("wm-lib://engines/shader-v1.js")), "a3fb953e485aecd353986946d510f19e313ac5938e823920875176fe1e628702")
    }
}
