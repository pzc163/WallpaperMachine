import AppKit
import SwiftUI
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorConnectionDraftsTests: PanelTestCase {
    func testCloudAndLocalEditorsRetainOnlyTheirOwnUnsavedFields() throws {
        let drafts = CreatorConnectionDrafts()
        let cloudEntry = try XCTUnwrap(CreatorProviderCatalog.entry("deepseek"))
        let localEntry = try XCTUnwrap(CreatorProviderCatalog.entry("lmstudio"))
        drafts.select(cloudEntry, profiles: [])
        let cloud = drafts.selected
        cloud.key = "cloud-fixture-key"; cloud.profile.model = "cloud-model"
        drafts.select(localEntry, profiles: [])
        let local = drafts.selected
        XCTAssertFalse(local === cloud)
        XCTAssertNotEqual(local.id, cloud.id)
        XCTAssertTrue(local.key.isEmpty)
        XCTAssertEqual(local.profile.baseURL, "http://127.0.0.1:1234/v1")
        local.profile.baseURL = "http://192.168.90.9:1234/v1"
        local.key = "local-fixture-key"; local.profile.model = "local-model"
        drafts.select(cloudEntry, profiles: [])
        XCTAssertTrue(drafts.selected === cloud)
        XCTAssertEqual(cloud.profile.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(cloud.key, "cloud-fixture-key")
        drafts.select(localEntry, profiles: [])
        XCTAssertTrue(drafts.selected === local)
        XCTAssertEqual(local.profile.baseURL, "http://192.168.90.9:1234/v1")
        XCTAssertEqual(local.key, "local-fixture-key")
        local.targetChanged()
        XCTAssertTrue(local.key.isEmpty)
        XCTAssertEqual(cloud.key, "cloud-fixture-key")
        XCTAssertFalse(String(reflecting: cloud).contains("cloud-fixture-key"))
        XCTAssertTrue(Mirror(reflecting: cloud).children.isEmpty)
        drafts.clearKeys()
        XCTAssertTrue(cloud.key.isEmpty)
    }

    func testLegacyLocalRecordCannotBeReusedByTheCloudPreset() throws {
        let entry = try XCTUnwrap(CreatorProviderCatalog.entry("deepseek"))
        var legacy = entry.profile(); legacy.localMode = true
        legacy.baseURL = "http://192.168.90.9:1234/v1"; legacy.model = "legacy-local"
        let drafts = CreatorConnectionDrafts()
        drafts.select(legacy); drafts.selected.key = "local-fixture-key"
        drafts.select(entry, profiles: [legacy])
        XCTAssertNotEqual(drafts.selected.id, legacy.id)
        XCTAssertFalse(drafts.selected.profile.localMode)
        XCTAssertEqual(drafts.selected.profile.baseURL, entry.endpoints[0])
        XCTAssertTrue(drafts.selected.key.isEmpty)
        drafts.select(legacy)
        XCTAssertEqual(drafts.selected.key, "local-fixture-key")
    }

    func testSavingOrDeletingOneDraftDoesNotClearTheOtherKind() throws {
        let drafts = CreatorConnectionDrafts()
        drafts.select(try XCTUnwrap(CreatorProviderCatalog.entry("openai")), profiles: [])
        let cloud = drafts.selected; cloud.key = "cloud-fixture-key"
        drafts.select(try XCTUnwrap(CreatorProviderCatalog.entry("custom-local")), profiles: [])
        let local = drafts.selected; local.key = "local-fixture-key"
        var saved = cloud.profile; saved.configurationRevision = 1; saved.credentialNamespace = .cloud
        drafts.saved(saved, submitted: cloud.profile)
        XCTAssertTrue(cloud.key.isEmpty)
        XCTAssertEqual(cloud.profile, saved)
        XCTAssertEqual(local.key, "local-fixture-key")
        drafts.remove(cloud.id)
        XCTAssertTrue(drafts.selected === local)
        XCTAssertEqual(local.key, "local-fixture-key")
    }

    func testLateSaveDoesNotOverwriteNewInput() throws {
        let drafts = CreatorConnectionDrafts()
        drafts.select(try XCTUnwrap(CreatorProviderCatalog.entry("openai")), profiles: [])
        let original = drafts.selected.profile
        var saved = original; saved.configurationRevision = 1; saved.credentialNamespace = .cloud
        drafts.selected.profile.model = "edited-while-saving"
        drafts.saved(saved, submitted: original)
        XCTAssertEqual(drafts.selected.profile.model, "edited-while-saving")
    }

    func testAddingAnotherCustomConnectionCreatesANewIndependentDraftAfterSave() throws {
        for local in [false, true] {
            let drafts = CreatorConnectionDrafts()
            let entry = try XCTUnwrap(CreatorProviderCatalog.entry(local ? "custom-local" : "custom-cloud"))
            drafts.select(entry, profiles: [])
            let first = drafts.selected
            first.profile.name = "First connection"; first.profile.model = "first-model"
            first.profile.baseURL = local ? "http://localhost:1234/v1" : "https://example.test/v1"
            first.key = "first-fixture-key"
            let submitted = first.profile
            var saved = submitted; saved.configurationRevision = 1
            saved.configurationID = UUID(); saved.credentialNamespace = saved.connectionKind
            drafts.saved(saved, submitted: submitted)
            drafts.select(entry, profiles: [saved])
            let second = drafts.selected
            XCTAssertNotEqual(second.id, first.id)
            XCTAssertTrue(second.profile.baseURL.isEmpty); XCTAssertTrue(second.key.isEmpty)
            second.key = "second-fixture-key"
            drafts.select(entry, profiles: [saved])
            XCTAssertTrue(drafts.selected === second, "Keep an unsaved draft when browsing the directory")
            drafts.select(saved)
            XCTAssertEqual(drafts.selected.profile, saved)
            XCTAssertTrue(drafts.selected.key.isEmpty)
            XCTAssertEqual(second.key, "second-fixture-key")
        }
    }

    func testProtocolChangesKeepTheConnectionKindAndClearOnlyItsTransientKey() throws {
        for local in [false, true] {
            let draft = CreatorConnectionDraft(try XCTUnwrap(CreatorProviderCatalog.entry(local ? "lmstudio" : "openai")).profile())
            let id = draft.id, endpoint = draft.profile.baseURL
            for kind in ProviderProfile.ProtocolKind.allCases {
                draft.key = "fixture-key"; draft.models = ["previous-protocol-model"]
                draft.changeProtocol(to: kind)
                XCTAssertEqual(draft.profile.localMode, local)
                XCTAssertEqual(draft.id, id); XCTAssertEqual(draft.profile.baseURL, endpoint)
                XCTAssertEqual(draft.profile.protocolKind, kind)
                XCTAssertEqual(draft.keyIsOptional, local && kind == .openaiCompatible)
                XCTAssertTrue(draft.key.isEmpty); XCTAssertTrue(draft.models.isEmpty)
            }
        }
    }

    func testCloudAndLocalFormsShowEditableEndpointThenKeyThenModelOffscreen() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        defer { PanelLocale.shared.bind(to: .testHost) }
        do {
            for local in [false, true] {
                let entry = try XCTUnwrap(CreatorProviderCatalog.entry(local ? "lmstudio" : "deepseek"))
                let draft = CreatorConnectionDraft(entry.profile())
                for language in AppLanguage.supported {
                    PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language.tag]))
                    for width in [390.0, 740.0] {
                        let page = CreatorProviderConnectionForm(form: draft, didSave: { _, _ in }, didDelete: { _ in })
                            .environment(panel.controller).panelTheme(theme: panel.controller.theme, locale: PanelLocale.shared)
                        let hosting = NSHostingController(rootView: page); hosting.sizingOptions = []
                        let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
                        defer { window.contentViewController = nil; window.close() }
                        window.setContentSize(NSSize(width: width, height: 1400))
                        hosting.view.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(60))
                        hosting.view.layoutSubtreeIfNeeded()
                        let elements = AccessibilityElement.everything(in: hosting.view)
                        let endpoint = try XCTUnwrap(elements.first { $0.identifier == "creator-profile-endpoint" })
                        let key = try XCTUnwrap(elements.first { $0.identifier == "creator-profile-key" })
                        let model = try XCTUnwrap(elements.first { $0.identifier == "creator-profile-model" })
                        XCTAssertEqual(endpoint.role, "AXTextField")
                        XCTAssertEqual(endpoint.value, draft.profile.baseURL)
                        let ys = try [endpoint, key, model].map { element in
                            try XCTUnwrap(element.object.value(forKey: "accessibilityFrame") as? NSValue).rectValue.midY
                        }
                        XCTAssertGreaterThan((ys[1] - ys[0]) * (ys[2] - ys[1]), 0, "API key must sit between Base URL and Model ID")
                        XCTAssertEqual(elements.contains { $0.identifier == "creator-fetch-models" }, local)
                        XCTAssertTrue(elements.contains { $0.identifier == "creator-test-connection" }, "New and unsaved forms keep the connection test visible")
                        XCTAssertFalse(elements.contains { $0.text == L("Local server mode") })
                    }
                }
            }
            XCTAssertEqual(c.memory.readCount, 0, "Rendering forms must never read personal credentials")
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }

    func testConnectionReadinessUsesEditedAddressModelAndKeyWithoutPersisting() throws {
        let form = CreatorConnectionDraft(try XCTUnwrap(CreatorProviderCatalog.entry("lmstudio")).profile())
        XCTAssertFalse(form.canTest)
        form.profile.baseURL = "http://192.168.90.9:1234/v1"; form.profile.model = "local-model"
        XCTAssertTrue(form.canTest); XCTAssertTrue(form.needsSave(comparedTo: nil))
        let saved = form.profile
        XCTAssertFalse(form.needsSave(comparedTo: saved))
        form.key = "replacement-fixture-key"
        XCTAssertTrue(form.needsSave(comparedTo: saved), "Test must not silently ignore a changed key")
        form.profile.baseURL = "http://public.example/v1"
        XCTAssertFalse(form.canTest)
    }
}
