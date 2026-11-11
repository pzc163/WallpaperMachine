import AppKit
import SwiftUI
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorModelSettingsTests: PanelTestCase {
    func testJSONModesPersistAndRotateCredentialBindingBeforeAnyRequest() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let panel = try makeController(creatorWorkspace: workspace)
        do {
            let controller = panel.controller
            try await controller.recoverCreator()
            try await controller.selectCreatorProfile(c.profile.id)
            panel.dialogs.confirmAnswer = true
            for mode: ProviderProfile.Capabilities.JSONMode in [.automatic, .schema, .required, .disabled] {
                var draft = try XCTUnwrap(controller.creator.profile)
                let oldID = draft.configurationID, oldRevision = draft.configurationRevision
                draft.capabilities.jsonMode = mode
                try await controller.saveCreatorProfile(draft, key: "", expectedRevision: controller.creator.configuration.revision)
                let saved = try XCTUnwrap(controller.creator.profile)
                XCTAssertNotEqual(saved.configurationID, oldID)
                XCTAssertEqual(saved.configurationRevision, oldRevision + 1)
                let reloaded = try await CreatorSettingsStore(url: c.settings.url).settings()
                XCTAssertEqual(reloaded.profiles.first?.capabilities.jsonMode, mode)
                let sent = c.route.requests.count
                do { try await controller.testCreatorConnection(saved); XCTFail("Used old credential after mode change") } catch {}
                XCTAssertEqual(c.route.requests.count, sent)
                try await controller.saveCreatorProfile(saved, key: LLMTestFixtures.key, expectedRevision: controller.creator.configuration.revision)
                XCTAssertEqual(controller.creator.profile?.configurationID, saved.configurationID)
                c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(#"{"ok":true}"#)])])
                try await controller.testCreatorConnection(saved)
                XCTAssertEqual(c.route.requests.count, sent + 1)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(c.route.requests.last?.httpBody)) as? [String: Any])
                let format = body["response_format"] as? [String: Any]
                switch mode {
                case .schema, .automatic: XCTAssertEqual(format?["type"] as? String, "json_schema")
                case .required: XCTAssertEqual(format?["type"] as? String, "json_object")
                case .disabled: XCTAssertNil(format)
                }
            }
            XCTAssertFalse(try String(contentsOf: c.settings.url, encoding: .utf8).contains(LLMTestFixtures.key))
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }

    func testSavingModeChangeCancelsOldConnectionAndRejectsStaleDraft() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            let controller = panel.controller
            try await controller.recoverCreator()
            panel.dialogs.confirmAnswer = true; c.route.replace([.init(hold: true)])
            let request = Task { try await controller.testCreatorConnection(c.profile) }
            try await c.waitForRequest()
            let revision = controller.creator.configuration.revision
            var draft = c.profile; draft.capabilities.jsonMode = .schema
            try await controller.saveCreatorProfile(draft, key: "", expectedRevision: revision)
            do { try await request.value; XCTFail("Old connection succeeded") } catch {}
            let saved = controller.creator.configuration
            do { try await controller.saveCreatorProfile(c.profile, key: LLMTestFixtures.key, expectedRevision: revision); XCTFail("Stale draft accepted") } catch {}
            XCTAssertEqual(controller.creator.configuration, saved)
            XCTAssertFalse(controller.creator.isTestingConnection)
            XCTAssertNil(controller.creator.connectionNotice)
            XCTAssertEqual(c.route.requests.count, 1)
            XCTAssertFalse(c.diagnostics.lines.joined().contains(LLMTestFixtures.key))
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }

    func testJSONSelectorNativeProtocolNotesAndPresetMenuRenderInAllLanguagesOffscreen() async throws {
        defer { PanelLocale.shared.bind(to: .testHost) }
        for kind in ProviderProfile.ProtocolKind.allCases {
            let c = try await LLMTestContext(kind: kind, capabilities: kind == .openaiCompatible ? .init(jsonMode: .schema) : .init())
            defer { c.cleanup() }
            let original = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
            let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
            do {
                let controller = panel.controller
                try await controller.recoverCreator(); try await controller.selectCreatorProfile(c.profile.id)
                try await controller.selectCreatorProject(original.projectID)
                for language in AppLanguage.supported {
                    PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language.tag]))
                    for page in [AnyView(CreatorSettingsSection()), AnyView(CreatorInspector())] {
                        controller.creator.providerAdvancedExpanded = false
                        let hosting = NSHostingController(rootView: page.environment(controller).panelTheme(theme: controller.theme, locale: PanelLocale.shared))
                        hosting.sizingOptions = []
                        let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
                        defer { window.contentViewController = nil; window.close() }
                        window.setContentSize(NSSize(width: 700, height: 1400))
                        hosting.view.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                        hosting.view.layoutSubtreeIfNeeded()
                        var elements = AccessibilityElement.everything(in: hosting.view)
                        if elements.contains(where: { $0.identifier == "creator-model-settings" }) {
                            for identifier in ["creator-profile-name", "creator-profile-protocol", "creator-profile-endpoint", "creator-profile-model", "creator-profile-key"] {
                                XCTAssertTrue(elements.contains { $0.identifier == identifier }, "\(language.tag): \(identifier)")
                            }
                            XCTAssertTrue(elements.contains { $0.identifier == "creator-advanced-options" })
                            XCTAssertFalse(elements.contains { $0.identifier == "creator-json-mode" }, "Advanced controls start collapsed")
                            controller.creator.providerAdvancedExpanded = true
                            try await Task.sleep(for: .milliseconds(100)); hosting.view.layoutSubtreeIfNeeded()
                            elements = AccessibilityElement.everything(in: hosting.view)
                            if kind == .openaiCompatible {
                                let picker = try XCTUnwrap(elements.first { $0.identifier == "creator-json-mode" }, "\(language.tag) \(kind) expanded=\(controller.creator.providerAdvancedExpanded) identifiers=\(elements.map(\.identifier).filter { !$0.isEmpty })")
                                XCTAssertEqual(picker.value, PanelLocale.shared.catalogString("JSON Schema (strict)"))
                            } else {
                                XCTAssertFalse(elements.contains { $0.identifier == "creator-json-mode" })
                                XCTAssertTrue(elements.contains { $0.identifier == "creator-json-mode-native" })
                            }
                        } else {
                            XCTAssertTrue(elements.contains { $0.identifier == "creator-presets" }, language.tag)
                        }
                        let size = NSSize(width: 320, height: 560)
                        window.setContentSize(size); hosting.view.layoutSubtreeIfNeeded()
                        let taken = hosting.sizeThatFits(in: size)
                        XCTAssertLessThanOrEqual(taken.width, 321, language.tag)
                        XCTAssertTrue(taken.height.isFinite)
                        XCTAssertFalse(window.isVisible)
                    }
                }
                XCTAssertTrue(c.route.requests.isEmpty); XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
            } catch { await panel.shutdown(); throw error }
            await panel.shutdown()
        }
    }
}
