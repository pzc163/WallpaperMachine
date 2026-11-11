import AppKit
import SwiftUI
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorArtifactTests: PanelTestCase {
    func testCompletedStreamIsArchivedByTurnAndSourceClipboardUsesAnIsolatedPasteboard() async throws {
        let c = try await LLMTestContext(tokens: 24_576); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            let controller = panel.controller
            try await controller.recoverCreator(); try await controller.selectCreatorProfile(c.profile.id)
            try await controller.setCreatorEngine(.htmlCanvas); controller.creator.prompt = "Create a violet field"
            c.route.replace([.init(chunks: [try LLMTestFixtures.openAI("<think>plan the field</think>" + CreatorCodeWorkflowTests.html)])])
            try await controller.generateCreator()
            let turn = try XCTUnwrap(controller.creator.detail?.conversation.turns.last)
            let transcript = try XCTUnwrap(controller.creator.transcripts[turn.id])
            XCTAssertTrue(transcript.completed); XCTAssertFalse(transcript.isThinking)
            XCTAssertTrue(transcript.progress.reasoning.contains("plan the field"))
            XCTAssertNil(controller.creator.activeTranscript)
            XCTAssertEqual(controller.creator.artifactTab, .render)
            XCTAssertEqual(controller.creator.artifactSource, CreatorCodeWorkflowTests.html)
            XCTAssertNil(controller.creator.embedded.view, "No visible panel, so no implicit WebKit surface")
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            controller.copyCreatorSource(to: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), CreatorCodeWorkflowTests.html)
            XCTAssertFalse(String(decoding: try CreatorPersistence.record(controller.creator.detail!.conversation), as: UTF8.self).contains("plan the field"))
            XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testSessionTranscriptRetentionIsBoundedAndCloseClearsIt() {
        let model = CreatorModel()
        for _ in 0..<12 {
            model.activeTranscript = CreatorTranscript()
            model.receiveStream(.init(phase: .thinking, reasoning: String(repeating: "a", count: 1024 * 1024)))
            model.archiveTranscript(for: UUID())
        }
        XCTAssertLessThanOrEqual(model.transcripts.count, 8)
        XCTAssertLessThanOrEqual(model.transcripts.values.reduce(0) { $0 + $1.byteCount }, 8 * 1024 * 1024)
        model.close(); XCTAssertTrue(model.transcripts.isEmpty); XCTAssertNil(model.embedded.view)
    }
    func testEmbeddedPreviewRequiresSealedUntamperedRevisionAndStopsWithoutWindow() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorCodeWorkflowTests.html)])])
        let result = try await CreatorWorkspaceTests.workspace(c).generate(CreatorCodeWorkflowTests.request(c))
        let preview = CreatorEmbeddedPreview(); defer { preview.close() }
        do { try await preview.open(project: result.projectID, revision: result.draft.id, store: c.store); XCTFail("Unsealed preview accepted") } catch {}
        XCTAssertNil(preview.view)
        try await preview.open(project: result.projectID, revision: result.sealed.id, store: c.store)
        XCTAssertNotNil(preview.view); XCTAssertNil(preview.view?.window)
        try preview.pause(true); XCTAssertTrue(preview.paused)
        try preview.pause(false); XCTAssertFalse(preview.paused)
        preview.close(); XCTAssertNil(preview.view); XCTAssertEqual(preview.state, .idle)
        let source = c.store.bundleURL(projectID: result.projectID, revisionID: result.sealed.id).appendingPathComponent("index.html")
        try Data((CreatorCodeWorkflowTests.html + " ").utf8).write(to: source)
        do { try await preview.open(project: result.projectID, revision: result.sealed.id, store: c.store); XCTFail("Tampered preview accepted") } catch {}
        XCTAssertNil(preview.view)
    }
    func testArtifactAndThinkingRenderInSixLanguagesAtNarrowWidthsWithoutIO() async throws {
        defer { PanelLocale.shared.bind(to: .testHost) }
        try await withPanel { panel in
            let controller = panel.controller
            controller.creator.showsGallery = false; controller.creator.conversationExpanded = true
            controller.creator.activeTranscript = CreatorTranscript()
            controller.creator.receiveStream(.init(phase: .content, characters: 60, content: "```html\n<html>\n<body>test</body></html>", reasoning: "Model plan"))
            controller.creator.artifactTab = .source
            for language in AppLanguage.supported {
                PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language.tag]))
                let hosting = NSHostingController(rootView: CreatorPage().environment(controller).panelTheme(theme: controller.theme, locale: PanelLocale.shared))
                hosting.sizingOptions = []
                let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
                defer { window.contentViewController = nil; window.close() }
                for width in [CGFloat(700), 340] {
                    window.setContentSize(NSSize(width: width, height: 900)); hosting.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100)); hosting.view.layoutSubtreeIfNeeded()
                    XCTAssertLessThanOrEqual(hosting.sizeThatFits(in: NSSize(width: width, height: 900)).width, width + 1)
                    let elements = AccessibilityElement.everything(in: hosting.view)
                    XCTAssertTrue(elements.contains { $0.identifier == "creator-artifact" })
                    XCTAssertTrue(elements.contains { $0.identifier == "creator-thinking" })
                }
                XCTAssertFalse(window.isVisible); XCTAssertNil(controller.creator.embedded.view)
            }
        }
    }
}
