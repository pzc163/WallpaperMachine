import AppKit
import SwiftUI
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorComposerTests: PanelTestCase {
    func testReturnSubmitsButShiftReturnAndIMEConfirmationDoNot() {
        XCTAssertTrue(CreatorPromptEditor.Editor.sends(keyCode: 36, modifiers: [], marked: false))
        XCTAssertTrue(CreatorPromptEditor.Editor.sends(keyCode: 76, modifiers: [], marked: false))
        for modifiers: NSEvent.ModifierFlags in [.shift, .option, .command, .control] {
            XCTAssertFalse(CreatorPromptEditor.Editor.sends(keyCode: 36, modifiers: modifiers, marked: false))
        }
        XCTAssertFalse(CreatorPromptEditor.Editor.sends(keyCode: 36, modifiers: [], marked: true))
        XCTAssertFalse(CreatorPromptEditor.Editor.sends(keyCode: 0, modifiers: [], marked: false))
    }
    func testAutomaticDisplayNameIsShortAndNeverOverwritesExplicitNameOrIdentity() async throws {
        XCTAssertEqual(CreatorProjectNaming.title(from: "请帮我生成一个纯黑背景上的紫色流体墨水，跟随指针移动"), "纯黑背景上的紫色流体墨水，跟随指针移")
        XCTAssertNil(CreatorProjectNaming.title(from: "   "))
        XCTAssertLessThanOrEqual(try XCTUnwrap(CreatorProjectNaming.title(from: String(repeating: "🌌", count: 40))).count, 18)
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let first = try await c.store.createProject(title: "未命名工程")
        try await c.store.nameFirstPrompt(first.id, sanitizedPrompt: "请生成一个蓝紫色极光")
        var rows = try await c.store.workspaceProjects()
        XCTAssertEqual(rows.first { $0.id == first.id }?.title, "蓝紫色极光")
        let untouched = try await c.store.project(first.id)
        XCTAssertEqual(untouched.identityDigest, first.identityDigest)
        try await c.store.setDisplayName(first.id, title: "My title")
        try await c.store.nameFirstPrompt(first.id, sanitizedPrompt: "New prompt")
        rows = try await c.store.workspaceProjects()
        XCTAssertEqual(rows.first { $0.id == first.id }?.title, "My title")
        let manual = try await c.store.createProject(title: "My project")
        try await c.store.nameFirstPrompt(manual.id, sanitizedPrompt: "No overwrite")
        rows = try await c.store.workspaceProjects()
        XCTAssertEqual(rows.first { $0.id == manual.id }?.title, "My project")
    }
    func testFailedTurnEditFocusAndRetryUseOriginalPromptAndCurrentProfile() async throws {
        let c = try await LLMTestContext(tokens: 24_576); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            let controller = panel.controller
            try await controller.recoverCreator(); try await controller.selectCreatorProfile(c.profile.id)
            try await controller.newCreatorProject()
            controller.creator.prompt = "请帮我生成一个蓝紫色极光"
            c.route.replace([.init(status: 401)])
            do { try await controller.generateCreator(); XCTFail("Unauthorized request passed") } catch {}
            let turn = try XCTUnwrap(controller.creator.detail?.conversation.turns.last)
            XCTAssertEqual(turn.state, .failed)
            XCTAssertEqual(controller.creator.projects.first?.title, "蓝紫色极光")
            let oldFocus = controller.creator.composerFocusID
            controller.creator.prompt = "different prompt"
            try controller.editCreatorTurn(turn.id)
            XCTAssertEqual(controller.creator.prompt, turn.userMessage)
            XCTAssertNotEqual(controller.creator.composerFocusID, oldFocus)
            c.route.replace([.init(status: 401), .init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
            try await controller.retryCreatorTurn(turn.id)
            XCTAssertEqual(controller.creator.phase, .ready); XCTAssertEqual(controller.creator.prompt, "")
            XCTAssertEqual(controller.creator.detail?.conversation.turns.map(\.userMessage), [turn.userMessage, turn.userMessage])
            XCTAssertEqual(controller.creator.detail?.conversation.turns.first?.state, .failed)
            XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
            XCTAssertFalse(controller.creator.canApply)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testNativeEditorGrowsThenScrollsWithoutTruncatingLongText() async throws {
        try await withPanel { panel in
            let model = panel.controller.creator
            model.prompt = "Short prompt"
            let hosting = NSHostingController(rootView: CreatorComposer().environment(panel.controller).panelTheme(theme: panel.controller.theme, locale: PanelLocale.shared))
            hosting.sizingOptions = []
            let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
            defer { window.contentViewController = nil; window.close() }
            window.setContentSize(NSSize(width: 420, height: 500))
            hosting.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.view.layoutSubtreeIfNeeded()
            func findEditor(_ view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                for child in view.subviews { if let text = findEditor(child) { return text } }
                return nil
            }
            let editor = try XCTUnwrap(findEditor(hosting.view)), scroll = try XCTUnwrap(editor.enclosingScrollView)
            let shortHeight = scroll.frame.height
            XCTAssertEqual(editor.string, "Short prompt")
            XCTAssertGreaterThan(editor.frame.width, 100)
            XCTAssertGreaterThanOrEqual(shortHeight, 75); XCTAssertLessThanOrEqual(shortHeight, 177)
            let long = Array(repeating: "A long prompt line", count: 20).joined(separator: "\n")
            model.prompt = long
            try await Task.sleep(for: .milliseconds(100)); hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(editor.string, long)
            XCTAssertGreaterThan(scroll.frame.height, shortHeight)
            XCTAssertLessThanOrEqual(scroll.frame.height, 177)
            XCTAssertTrue(scroll.hasVerticalScroller)
            XCTAssertFalse(window.isVisible)
        }
    }
    func testComposerAndSidebarRemainUsableInSixLanguagesAndNarrowOffscreenLayouts() async throws {
        defer { PanelLocale.shared.bind(to: .testHost) }
        try await withPanel { panel in
            let controller = panel.controller
            try await controller.recoverCreator(); try await controller.newCreatorProject()
            for language in AppLanguage.supported {
                PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language.tag]))
                for page in [AnyView(CreatorPage()), AnyView(CreatorProjectsList())] {
                    let hosting = NSHostingController(rootView: page.environment(controller).panelTheme(theme: controller.theme, locale: PanelLocale.shared))
                    hosting.sizingOptions = []
                    let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
                    defer { window.contentViewController = nil; window.close() }
                    window.setContentSize(NSSize(width: 360, height: 800))
                    hosting.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                    hosting.view.layoutSubtreeIfNeeded()
                    let elements = AccessibilityElement.everything(in: hosting.view)
                    if elements.contains(where: { $0.identifier == "creator-page" }) {
                        XCTAssertTrue(elements.contains { $0.identifier == "creator-prompt" }, language.tag)
                        XCTAssertTrue(elements.contains { $0.identifier == "creator-rename" }, language.tag + " rename: " + elements.compactMap(\.identifier).joined(separator: ","))
                        XCTAssertTrue(elements.contains { $0.identifier == "creator-model-picker" }, language.tag + " picker: " + elements.compactMap(\.identifier).joined(separator: ","))
                        XCTAssertFalse(elements.contains { $0.identifier == "page-search-field" }, "No duplicate search in workspace")
                        controller.creator.prompt = Array(repeating: "A long prompt line", count: 20).joined(separator: "\n")
                        hosting.view.layoutSubtreeIfNeeded()
                    } else {
                        XCTAssertEqual(elements.filter { $0.identifier == "page-search-field" }.count, 1)
                        XCTAssertTrue(elements.contains { $0.identifier == "creator-new" }, elements.compactMap(\.identifier).joined(separator: ","))
                    }
                    let taken = hosting.sizeThatFits(in: NSSize(width: 320, height: 650))
                    XCTAssertLessThanOrEqual(taken.width, 321, language.tag); XCTAssertTrue(taken.height.isFinite)
                    XCTAssertFalse(window.isVisible)
                }
            }
        }
    }
}
