import AppKit
import SwiftUI
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorPanelTests: PanelTestCase {
    func testNavigationSearchAndCompactInspectorUseExistingShellRules() async throws {
        try await withPanel { panel in
            let controller = panel.controller
            try await controller.navigate(.creator)
            XCTAssertEqual(PanelTabs.pages, [.wallpaper, .creator, .workshop, .pixiv, .settings])
            XCTAssertTrue(controller.shell.hasInspector); XCTAssertTrue(controller.shell.hasFilters)
            try await controller.newCreatorProject()
            controller.creator.search = "no-such-project"
            XCTAssertTrue(controller.creator.filteredProjects.isEmpty)
            controller.creator.search = ""
            XCTAssertEqual(controller.creator.filteredProjects.count, 1)
            controller.shell.windowWidthChanged(.compact)
            controller.shell.setFiltersShown(true)
            XCTAssertTrue(controller.shell.areFiltersShown); XCTAssertFalse(controller.shell.isInspectorShown)
            controller.shell.toggleInspector()
            XCTAssertFalse(controller.shell.areFiltersShown); XCTAssertTrue(controller.shell.isInspectorShown)
            try await controller.openSettings(.models)
            XCTAssertEqual(panel.navigation.settingsSection, .models)
            XCTAssertFalse(controller.shell.hasInspector)
        }
    }
    func testControllerGeneratesReadyWithoutImportOrDesktopAndShowsUsage() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let panel = try makeController(creatorWorkspace: workspace)
        do {
            try await panel.start(); try await panel.controller.recoverCreator()
            let controller = panel.controller
            let settings = try await workspace.configuration()
            _ = try await workspace.selectProfile(c.profile.id, expectedRevision: settings.revision)
            try await controller.selectCreatorProject(c.ticket.projectID)
            controller.creator.prompt = "A calm blue sky"; try CreatorWorkspaceTests.response(c)
            controller.creator.preview = CreatorPreviewWindow() // No window or renderer is opened.
            try await controller.generateCreator()
            XCTAssertNil(controller.creator.preview, "a new revision retires the old preview session")
            XCTAssertEqual(controller.creator.phase, .ready); XCTAssertFalse(controller.creator.isBusy)
            XCTAssertTrue(controller.creator.canSave); XCTAssertFalse(controller.creator.canApply)
            XCTAssertEqual(controller.creator.attempt, 1); XCTAssertNotNil(controller.creator.elapsed)
            XCTAssertNil(controller.creator.detail?.project.publishedWallpaperID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("Library").path))
            XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
            try await controller.openCreatorPreview(); XCTAssertNil(controller.creator.preview, "no real window under test")
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testControllerCancellationStopsRequestAndDoesNotPublish() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let panel = try makeController(creatorWorkspace: workspace)
        do {
            try await panel.start(); try await panel.controller.recoverCreator()
            let settings = try await workspace.configuration()
            _ = try await workspace.selectProfile(c.profile.id, expectedRevision: settings.revision)
            try await panel.controller.selectCreatorProject(c.ticket.projectID)
            panel.controller.creator.prompt = "Slow stars"
            c.route.replace([.init(hold: true)])
            let task = Task { try await panel.controller.generateCreator() }
            try await c.waitForRequest(); panel.controller.cancelCreator()
            do { try await task.value; XCTFail("Cancelled task succeeded") } catch {}
            XCTAssertEqual(panel.controller.creator.phase, .cancelled)
            XCTAssertFalse(panel.controller.creator.isBusy); XCTAssertEqual(c.route.requests.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("Library").path))
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testConnectionRequiresExplicitConfirmationAndDisplaysTarget() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            try await panel.controller.testCreatorConnection(c.profile)
            XCTAssertTrue(c.route.requests.isEmpty)
            let confirmation = try XCTUnwrap(panel.dialogs.confirmations.last)
            XCTAssertTrue(confirmation.detail.contains(c.profile.baseURL)); XCTAssertTrue(confirmation.detail.contains(c.profile.model))
            XCTAssertFalse(confirmation.detail.contains(LLMTestFixtures.key))
            panel.dialogs.confirmAnswer = true
            try await panel.controller.testCreatorConnection(c.profile)
            XCTAssertEqual(c.route.requests.count, 1); XCTAssertFalse(panel.controller.creator.isTestingConnection)
            XCTAssertEqual(panel.controller.creator.connectionStatus, L("Connection succeeded"))
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testStartupRecoversAbandonedJobWithoutEnteringCreatorTab() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        try await c.store.cancel(c.ticket)
        var abandoned: CreatorRevisionStore? = CreatorRevisionStore(root: c.store.root)
        let project = try await abandoned!.createProject(title: "Abandoned")
        let job = try await abandoned!.beginJob(projectID: project.id)
        abandoned = nil
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            try await panel.start()
            try await panel.waitUntil { panel.controller.creator.recovered }
            XCTAssertEqual(panel.navigation.selection, .wallpaper)
            XCTAssertTrue(panel.controller.creator.recovery?.interruptedJobs.contains(job.id) == true)
            let record = try await c.store.job(job.id); XCTAssertEqual(record.state, .interrupted)
            XCTAssertTrue(c.route.requests.isEmpty)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testDeleteDraftConfirmationDefaultsToKeepingEverything() async throws {
        try await withPanel { panel in
            try await panel.controller.recoverCreator(); try await panel.controller.newCreatorProject()
            let id = try XCTUnwrap(panel.controller.creator.selectedProjectID)
            try await panel.controller.deleteCreatorProject(id)
            XCTAssertEqual(panel.controller.creator.projects.count, 1)
            panel.dialogs.confirmAnswer = true
            try await panel.controller.deleteCreatorProject(id)
            XCTAssertTrue(panel.controller.creator.projects.isEmpty)
            XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
        }
    }
    func testCreatorPagesFitNarrowColumnsInEveryLanguageWithoutShowingWindows() async throws {
        try await withPanel { panel in
            let controller = panel.controller
            try await controller.recoverCreator()
            try await controller.newCreatorProject()
            defer { PanelLocale.shared.bind(to: .testHost) }
            for language in AppLanguage.supported {
                PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language.tag]))
                for page in [AnyView(CreatorPage()), AnyView(CreatorInspector()), AnyView(CreatorSettingsSection())] {
                    let host = NSHostingController(rootView: page.environment(controller).panelTheme(theme: controller.theme, locale: PanelLocale.shared))
                    host.sizingOptions = []
                    let size = NSSize(width: 320, height: 560)
                    let taken = host.sizeThatFits(in: size)
                    XCTAssertLessThanOrEqual(taken.width, 321, language.tag)
                    XCTAssertTrue(taken.height.isFinite)
                    XCTAssertNil(host.view.window)
                }
            }
        }
    }
    func testNewCopyAndProjectSelectionRetirePreviousPreviewSessions() async throws {
        try await withPanel { panel in
            let controller = panel.controller
            try await controller.recoverCreator(); try await controller.newCreatorProject()
            let first = try XCTUnwrap(controller.creator.selectedProjectID)
            controller.creator.preview = CreatorPreviewWindow()
            try await controller.newCreatorProject(); XCTAssertNil(controller.creator.preview)
            controller.creator.preview = CreatorPreviewWindow()
            try await controller.duplicateCreatorProject(first); XCTAssertNil(controller.creator.preview)
            controller.creator.preview = CreatorPreviewWindow()
            try await controller.selectCreatorProject(first); XCTAssertNil(controller.creator.preview)
            XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
        }
    }
    func testConnectionCanBeCancelledWhileInFlight() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            panel.dialogs.confirmAnswer = true; c.route.replace([.init(hold: true)])
            let task = Task { try await panel.controller.testCreatorConnection(c.profile) }
            try await c.waitForRequest(); panel.controller.cancelCreatorConnection()
            do { try await task.value; XCTFail("Cancelled probe succeeded") } catch {}
            XCTAssertFalse(panel.controller.creator.isTestingConnection)
            XCTAssertEqual(c.route.requests.count, 1)
            XCTAssertFalse((panel.controller.creator.connectionStatus ?? "").contains(LLMTestFixtures.key))
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testStartupRollsBackAnUnconfirmedPublicationJournal() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let sealed = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
        let ticket = try await workspace.publisher.prepare(projectID: sealed.projectID, revisionID: sealed.id, store: c.store)
        let installed = try await workspace.publisher.install(ticket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        let panel = try makeController(creatorWorkspace: workspace)
        do {
            try await panel.start(); try await panel.controller.recoverCreator()
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("publication/active").path))
            let report = try await c.store.report(projectID: sealed.projectID, revisionID: sealed.id)
            XCTAssertTrue(report.allowsPublication)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testTemplateAndSettingsKeysExistInEveryShippedLanguage() {
        for language in AppLanguage.supported {
            let locale = PanelLocale(language: language, region: nil)
            for definition in CreatorTemplateCatalog.all {
                for parameter in definition.parameters {
                    XCTAssertFalse(locale.catalogString(parameter.label).isEmpty)
                    if case .choice(let choices) = parameter.domain {
                        for choice in choices { XCTAssertFalse(locale.catalogString(choice.label).isEmpty) }
                    }
                }
            }
            XCTAssertFalse(locale.string(resolving: SettingsSection.models.title).isEmpty)
        }
        XCTAssertTrue(SettingsRegistry.problems(in: SettingsRegistry.items).isEmpty)
        XCTAssertEqual(SettingsRegistry.items(in: .models).map(\.id), ["models.profiles"])
    }
}
