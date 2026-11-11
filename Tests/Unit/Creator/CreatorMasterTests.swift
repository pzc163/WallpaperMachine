import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorMasterTests: XCTestCase {
    func testCatalogHasThreePerEngineAndDeterministicReferenceSelection() throws {
        let masters = try CreatorMasterCatalog.all()
        for engine in [CreatorEngine.shaderGLSL, .three3D, .htmlCanvas] {
            XCTAssertEqual(masters.filter { $0.engine == engine }.count, 3)
            XCTAssertNotNil(CreatorMasterCatalog.closest(prompt: "unclassified visual", engine: engine, masters: masters))
        }
        XCTAssertEqual(CreatorMasterCatalog.closest(prompt: "柔和的云海", engine: .shaderGLSL, masters: masters)?.id, "clouds")
        XCTAssertEqual(CreatorMasterCatalog.closest(prompt: "折射玻璃矩阵", engine: .three3D, masters: masters)?.id, "glass")
        XCTAssertEqual(CreatorMasterCatalog.closest(prompt: "机械齿轮时钟", engine: .htmlCanvas, masters: masters)?.id, "clockwork")
        XCTAssertNil(CreatorMasterCatalog.closest(prompt: "future", engine: .scene25D, masters: masters))
        for master in masters { XCTAssertGreaterThan(master.parameters.parameters.count, 5); XCTAssertEqual(try master.source(), try master.source()) }
    }
    func testNineMastersRenderRealNativePostersWithoutModelOrDesktop() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        for master in try CreatorMasterCatalog.all() {
            do {
                let id = try await workspace.createMaster(master.id), detail = try await workspace.detail(id)
                let revision = try XCTUnwrap(detail.project.selectedRevisionID)
                let snapshot = try await c.store.snapshot(projectID: id, revisionID: revision)
                let report = try await c.store.report(projectID: id, revisionID: revision)
                XCTAssertTrue(report.allowsPublication, master.id)
                XCTAssertGreaterThan(report.measuredMetrics["distinctColors"] ?? 0, 12, master.id)
                let jpeg = try XCTUnwrap(snapshot.files["preview.jpg"])
                let attachment = XCTAttachment(data: jpeg, uniformTypeIdentifier: "public.jpeg")
                attachment.name = "creator-master-" + master.id; attachment.lifetime = .keepAlways; add(attachment)
            } catch { XCTFail(master.id + ": " + String(describing: error)) }
        }
        XCTAssertTrue(c.route.requests.isEmpty)
    }
    func testMasterCreationCancellationCleansDraftAndIterationPreservesParent() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let before = try await workspace.projects()
        let cancelled = Task { try await workspace.createMaster("glass") }; cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled master stored") } catch {}
        let after = try await workspace.projects(); XCTAssertEqual(before.map(\.id), after.map(\.id))
        let id = try await workspace.createMaster("ink"), detail = try await workspace.detail(id)
        let base = try XCTUnwrap(detail.project.selectedRevisionID)
        let original = try await c.store.snapshot(projectID: id, revisionID: base)
        let core = try XCTUnwrap(CreatorEngineDocument.read(try XCTUnwrap(detail.source)))
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(core.core)])])
        var request = CreatorCodeWorkflowTests.request(c); request.projectID = id; request.baseRevisionID = base; request.engine = .shaderGLSL
        let result = try await workspace.generate(request)
        XCTAssertEqual(result.draft.parentID, base)
        let retained = try await c.store.snapshot(projectID: id, revisionID: base)
        XCTAssertEqual(retained.files, original.files)
        let body = String(decoding: try XCTUnwrap(c.route.requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("@pass BufferA")); XCTAssertTrue(body.contains("p_dissipation"))
    }
}
