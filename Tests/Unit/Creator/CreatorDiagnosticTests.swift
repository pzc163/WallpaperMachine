import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorDiagnosticTests: XCTestCase {
    func testStaticSyntaxReportsActualHTMLLineWithoutExecutingScript() throws {
        let html = "<!doctype html><html><body>\n<script>\nthrow new Error('must never execute');\nconst value = ;\n</script></body></html>"
        XCTAssertThrowsError(try CreatorCodeOutput.validateHTML(Data(html.utf8))) { error in
            let issue = error as? CreatorRepairIssue
            XCTAssertEqual(issue?.stage, .staticValidation)
            XCTAssertEqual(issue?.diagnostic?.code, .syntax)
            XCTAssertEqual(issue?.diagnostic?.source, .indexHTML)
            XCTAssertEqual(issue?.diagnostic?.line, 4)
        }
        let safeCompile = "<!doctype html><html><body><script>while(true){}</script></body></html>"
        XCTAssertNoThrow(try CreatorCodeOutput.validateHTML(Data(safeCompile.utf8)))
    }
    func testPageDiagnosticRejectsPathsMessagesAndOutOfRangeLocations() throws {
        let html = "<!doctype html>\n<html>\n<script>missing();</script></html>"
        let input = #"{"code":"reference","source":"about:srcdoc","line":4,"column":9,"message":"Bearer fixture-private-key /Users/private/file","stack":"secret-stack"}"#
        let item = try XCTUnwrap(CreatorSourceDiagnostic.fromPage(input, html: html))
        XCTAssertEqual(item.line, 3); XCTAssertEqual(item.column, 9)
        let encoded = String(decoding: try CreatorPersistence.encode(item), as: UTF8.self)
        for value in ["Bearer", "/Users", "secret-stack", "fixture-private-key"] { XCTAssertFalse(encoded.contains(value)) }
        XCTAssertNil(CreatorSourceDiagnostic.fromPage(#"{"code":"reference","source":"file:///private/secret","line":20}"#, html: html)?.line)
        XCTAssertNil(CreatorSourceDiagnostic.fromPage(#"{"code":"reference","source":"about:srcdoc","line":999999999}"#, html: html)?.line)
        XCTAssertNil(CreatorSourceDiagnostic.fromPage(#"{"code":"untrusted-output"}"#, html: html))
        XCTAssertThrowsError(try CreatorSourceDiagnostic(code: .syntax, source: .indexHTML, line: -1).validate())
    }
    func testNativeWrapperMapsThreeSourceAndShaderPassWithoutOffByOne() {
        let html = "<script id=\"wm-engine\"></script><script id=\"wm-source\">\nfunction setupScene(){\nmissing();\n}</script>"
        let item = CreatorSourceDiagnostic.location(code: .reference, html: html, line: 3, column: 1)
        XCTAssertEqual(item.source, .authorJS); XCTAssertEqual(item.line, 3)
        let source = "// @pass BufferA\nvoid mainImage() {}\n// @pass Image\nvoid mainImage() {\nmissing();\n}"
        let shader = CreatorSourceDiagnostic(code: .shaderCompile, source: .Image, line: 2)
        XCTAssertEqual(CreatorDiagnosticPresentation.displayLine(shader, in: source), 5)
        XCTAssertTrue(CreatorDiagnosticPresentation.excerpt(shader, source: source)?.contains("> 5:") == true)
        XCTAssertEqual(CreatorStreamTextView.range(line: 2, in: "🌙\n错误();"), NSRange(location: 3, length: 5))
    }
    func testBlackAndTransparentFramesHaveDifferentRepairDiagnostics() throws {
        for (alpha, expected): (CGFloat, CreatorSourceDiagnostic.Code) in [(1, .blankFrame), (0, .transparentFrame)] {
            let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
                NSColor.black.withAlphaComponent(alpha).setFill(); bounds.fill(); return true
            }
            XCTAssertThrowsError(try CreatorPosterImage.encode(image)) { error in
                let issue = error as? CreatorRepairIssue
                XCTAssertEqual(issue?.runtimeReason, .invalidCapture)
                XCTAssertEqual(issue?.diagnostic?.code, expected)
                XCTAssertEqual(issue?.stage, .capture)
            }
        }
    }
    func testCopiedReportContainsActionableEvidenceButNoSourceOrModelText() throws {
        let issue = CreatorRepairIssue(category: .runtime, runtimeReason: .script, stage: .runtime,
            diagnostic: .init(code: .reference, source: .indexHTML, line: 12, column: 3))
        try issue.validate()
        let report = CreatorDiagnosticPresentation.copiedReport(issue)
        XCTAssertTrue(report.contains("reference")); XCTAssertTrue(report.contains("12"))
        XCTAssertFalse(report.contains("http")); XCTAssertFalse(report.contains("/Users"))
        let source = "const token = 'sk-private123';"
        let excerpt = CreatorDiagnosticPresentation.excerpt(.init(code: .syntax, source: .indexHTML, line: 1), source: source)
        XCTAssertFalse(excerpt?.contains("sk-private123") == true)
    }
    func testCodeCanBeRevalidatedWithoutModelOrPublicationAndOldRevisionSurvives() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        try await c.store.cancel(c.ticket)
        let first = try await workspace.validateSource(project: c.ticket.projectID, base: nil, source: CreatorCodeWorkflowTests.html, engine: .htmlCanvas)
        let before = try await c.store.snapshot(projectID: first.projectID, revisionID: first.id)
        do {
            _ = try await workspace.validateSource(project: first.projectID, base: first.id, source: "<!doctype html><html><script>const broken = ;</script></html>", engine: .htmlCanvas)
            XCTFail("Invalid code passed")
        } catch { XCTAssertEqual((error as? CreatorRepairIssue)?.diagnostic?.code, .syntax) }
        let second = try await workspace.validateSource(project: first.projectID, base: first.id, source: CreatorCodeWorkflowTests.html, engine: .htmlCanvas)
        XCTAssertNotEqual(first.id, second.id)
        let after = try await c.store.snapshot(projectID: first.projectID, revisionID: first.id)
        XCTAssertEqual(before.files, after.files)
        XCTAssertTrue(c.route.requests.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("Library").path))
        let report = try await c.store.report(projectID: second.projectID, revisionID: second.id)
        XCTAssertTrue(report.allowsPublication)
    }
}
