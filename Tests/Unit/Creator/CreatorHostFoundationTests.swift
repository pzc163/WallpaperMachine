import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorHostFoundationTests: XCTestCase {
    // Inactive WKWebViews intentionally suspend native rAF. Drive its clock deterministically,
    // while retaining the production SDK's 30 Hz limiter and pause/cancellation behavior.
    static let clock = """
    (()=>{if(top===window)return;const queue=new Map();let next=0,time=0;
    window.requestAnimationFrame=f=>{queue.set(++next,f);return next};window.cancelAnimationFrame=id=>queue.delete(id);
    window.__wmStep=dt=>{time+=dt;const batch=[...queue.values()];queue.clear();for(const f of batch)f(time)};})();
    """
    static let schema = CreatorParameterSchema(parameters: [
        .init(id: "speed", label: "Speed", type: .number, defaultValue: .number(1), min: 0, max: 3, step: 0.01),
        .init(id: "glow", label: "Glow", type: .boolean, defaultValue: .bool(true)),
        .init(id: "tint", label: "Tint", type: .color, defaultValue: .choice("#a04cff"))],
        values: ["speed": .number(1), "glow": .bool(true), "tint": .choice("#a04cff")])
    static func html(three: Bool = false) throws -> String {
        "<!doctype html><html><body><canvas id=\"c\"></canvas><script id=\"wm-params\" type=\"application/json\">" + (try schema.json()) + "</script>" +
        (three ? "<script src=\"wm-lib://three/bundle.js\"></script>" : "") + """
        <script>const c=document.getElementById('c'),ctx=c.getContext('2d');c.width=320;c.height=180;
        function draw(){ctx.fillStyle='#0a1020';ctx.fillRect(0,0,320,180);ctx.fillStyle=WallpaperHost.parameters.tint||'#a04cff';ctx.fillRect(20,20,140,100)};draw();WallpaperHost.onFrame(draw);WallpaperHost.onParameters(draw);
        </script></body></html>
        """
    }
    func testStrictMetadataTypesBoundsAndUnknownFields() throws {
        let text = try Self.schema.json()
        XCTAssertEqual(try CreatorParameterSchema.parse(text), Self.schema)
        var values = Self.schema.values; values["speed"] = .number(4)
        XCTAssertThrowsError(try Self.schema.validate(values))
        values["speed"] = .bool(true); XCTAssertThrowsError(try Self.schema.validate(values))
        XCTAssertThrowsError(try CreatorParameterSchema.parse(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"extra\":true")))
        XCTAssertThrowsError(try CreatorParameterSchema.parse(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1")))
        XCTAssertThrowsError(try CreatorParameterSchema.parse(text.replacingOccurrences(of: "speed", with: "constructor")))
        XCTAssertThrowsError(try CreatorParameterSchema.parse(text.replacingOccurrences(of: "#a04cff", with: "javascript:alert(1)")))
    }
    func testParameterEditsRebindSourceAndMetadataWithoutChangingOldBytes() throws {
        let html = try Self.html(), id = UUID()
        let first = try CreatorCodeOutput.specification(projectID: id, html: Data(html.utf8))
        var values = Self.schema.values; values["speed"] = .number(2)
        let next = try Self.schema.replacing(in: html, with: values)
        let second = try CreatorCodeOutput.specification(projectID: id, html: Data(next.utf8))
        XCTAssertNotEqual(first.codeDigest, second.codeDigest); XCTAssertEqual(first.parameters?["speed"], .number(1))
        XCTAssertEqual(second.parameters?["speed"], .number(2)); XCTAssertNotNil(second.libraryDigest)
        XCTAssertThrowsError(try CreatorCodeOutput.files(specification: first, html: Data(next.utf8)))
        XCTAssertEqual(try CreatorParameterSchema.read(next)?.values, values)
    }
    func testOfflineContentRuleCompiles() async throws { _ = try await CreatorWebResources.offlineRules() }
    func testNativeParameterRevisionRequiresNewRuntimeEvidenceAndNoModelCall() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let html = Data(try Self.html().utf8)
        let spec = try CreatorCodeOutput.specification(projectID: c.ticket.projectID, html: html)
        _ = try await c.store.stage(spec, for: c.ticket, source: html)
        let draft = try await c.store.commit(c.ticket, validatingStructure: true)
        let evidence = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: c.store)
        let first = try await c.store.seal(evidence)
        let workspace = CreatorWorkspaceTests.workspace(c)
        let original = try await c.store.snapshot(projectID: first.projectID, revisionID: first.id)
        var values = Self.schema.values; values["speed"] = .number(2)
        let second = try await workspace.edit(project: first.projectID, revision: first.id, parameters: values)
        let report = try await c.store.report(projectID: second.projectID, revisionID: second.id)
        XCTAssertTrue(report.allowsPublication); XCTAssertNotNil(second.posterDigest)
        let retained = try await c.store.snapshot(projectID: first.projectID, revisionID: first.id)
        XCTAssertEqual(retained.files, original.files); XCTAssertNotEqual(second.bundleDigest, first.bundleDigest)
        let derivedDraft = try await c.store.revision(projectID: second.projectID, revisionID: XCTUnwrap(second.parentID))
        XCTAssertEqual(derivedDraft.parentID, first.id); XCTAssertTrue(c.route.requests.isEmpty)
        let model = CreatorModel(); model.detail = try await workspace.detail(second.projectID)
        model.parameters = values; XCTAssertTrue(model.canSave)
        model.parameters["speed"] = .number(2.5); XCTAssertTrue(model.canSave); XCTAssertTrue(model.canApply)
        model.parameters["speed"] = .number(10001); XCTAssertFalse(model.canSave); XCTAssertFalse(model.canApply)
    }
    func testLibraryOnlyServesExactPinnedAssetNames() throws {
        XCTAssertGreaterThan(try CreatorLibrary.bytes("wm-lib://three/bundle.js").count, 100_000)
        for url in ["wm-lib://three/../bundle.js", "wm-lib://three/bundle.js?key=x", "wm-lib://three/bundle.js#x", "wm-lib://three/%62undle.js", "wm-lib://evil/bundle.js", "file:///tmp/index.js"] {
            XCTAssertThrowsError(try CreatorLibrary.bytes(url))
        }
    }
    func testRealSandboxLoadsOfflineThreeAndHostProperties() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let surface = try await CreatorCodeTestFixture.preview(root: root, source: Self.html(three: true)); defer { surface.stop() }
        let revision = try await CreatorCodeTestFixture.js(surface, "return WMLib.THREE.REVISION") as? String
        XCTAssertEqual(revision, "180")
        let room = try await CreatorCodeTestFixture.js(surface, "return typeof WMLib.RoomEnvironment") as? String
        XCTAssertEqual(room, "function")
        try surface.applyProperties(#"{"speed":{"value":2},"tint":{"value":"0 1 0"}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let value = try await CreatorCodeTestFixture.js(surface, "return WallpaperHost.parameters") as? [String: Any]
        XCTAssertEqual(value?["speed"] as? Double, 2); XCTAssertEqual(value?["tint"] as? String, "#00ff00")
        XCTAssertNil(surface.view.window)
    }
    func testDampedCursorAndPausedSchedulerRespectHostLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let surface = try await CreatorCodeTestFixture.preview(root: root, source: Self.html(), script: Self.clock); defer { surface.stop() }
        surface.page.creatorCode?.cursor(x: 0.9, y: 0.2, active: true)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await CreatorCodeTestFixture.js(surface, "for(let i=0;i<4;i++) __wmStep(34);return true")
        let cursor = try await CreatorCodeTestFixture.js(surface, "return WallpaperHost.cursor") as? [String: Double]
        XCTAssertGreaterThan(cursor?["x"] ?? 0, 0.5); XCTAssertLessThan(cursor?["x"] ?? 1, 0.91)
        XCTAssertGreaterThan(cursor?["active"] ?? 0, 0)
        try surface.setPaused(true); try await Task.sleep(for: .milliseconds(80))
        let before = try await CreatorCodeTestFixture.js(surface, "return WallpaperHost.frame") as? Int
        _ = try await CreatorCodeTestFixture.js(surface, "for(let i=0;i<4;i++) __wmStep(34);return true")
        let after = try await CreatorCodeTestFixture.js(surface, "return WallpaperHost.frame") as? Int
        XCTAssertEqual(before, after)
        try surface.setPaused(false); try await Task.sleep(for: .milliseconds(50))
        _ = try await CreatorCodeTestFixture.js(surface, "for(let i=0;i<4;i++) __wmStep(34);return true")
        let resumed = try await CreatorCodeTestFixture.js(surface, "return WallpaperHost.frame") as? Int
        XCTAssertGreaterThan(resumed ?? 0, after ?? 0); XCTAssertLessThanOrEqual((resumed ?? 0)-(after ?? 0), 6)
    }
}
