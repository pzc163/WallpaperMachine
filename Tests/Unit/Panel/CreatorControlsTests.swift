import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorControlsTests: PanelTestCase {
    func testEveryPresetUpdatesOpenPreviewAndRequiresRevalidationWithoutChangingPublishedBytes() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let registryURL = await workspace.registry.url
        let panel = try makeController(creatorWorkspace: workspace)
        panel.reportFromBridge(panel.store.settingsSnapshot)
        do {
            let controller = panel.controller
            try await controller.recoverCreator()
            for definition in CreatorTemplateCatalog.all {
                let original = try await CreatorS14Fixtures.sealed(store: c.store, template: definition.id)
                let installed = try await workspace.publish(project: original.projectID, revision: original.id)
                try await controller.selectCreatorProject(original.projectID)
                XCTAssertTrue(controller.creator.canApply)
                let before = try await c.store.snapshot(projectID: original.projectID, revisionID: original.id)
                let (_, surface) = try await CreatorPreview.make(projectID: original.projectID, revisionID: original.id, store: c.store)
                defer { surface.stop() }
                surface.view.setFrameSize(NSSize(width: 320, height: 180))
                surface.view.layoutSubtreeIfNeeded()
                try await surface.start()
                let deadline = ContinuousClock.now + .seconds(10)
                while !surface.page.isLoaded && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertTrue(surface.page.isLoaded)
                controller.creator.preview = CreatorPreviewWindow(surface: surface)
                try controller.pauseCreatorPreview(true)
                try await Task.sleep(for: .milliseconds(100))
                for preset in definition.presets {
                    let pixels = try await canvas(surface)
                    try controller.applyCreatorPreset(preset.id, templateID: definition.id)
                    XCTAssertEqual(controller.creator.parameters, preset.parameters)
                    XCTAssertTrue(controller.creator.hasParameterChanges)
                    XCTAssertFalse(controller.creator.canSave); XCTAssertFalse(controller.creator.canApply)
                    do { try await controller.saveCreatorToLibrary(); XCTFail("Saved unvalidated preset") } catch {}
                    do { try await controller.applyCreatorToDisplay(); XCTFail("Applied unvalidated preset") } catch {}
                    let end = ContinuousClock.now + .seconds(3)
                    var changed = try await canvas(surface)
                    while changed == pixels && ContinuousClock.now < end {
                        try await Task.sleep(for: .milliseconds(20)); changed = try await canvas(surface)
                    }
                    XCTAssertNotEqual(changed, pixels, "\(definition.id)/\(preset.id) must repaint the paused preview")
                    XCTAssertNil(surface.page.webView.window)
                    let published = try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registryURL,
                        publicationRoot: c.root.appendingPathComponent("publication"))
                    XCTAssertEqual(published.digest, original.bundleDigest)
                }
                try await controller.validateCreatorParameters()
                XCTAssertNil(controller.creator.preview)
                XCTAssertNotEqual(controller.creator.selectedRevision?.id, original.id)
                XCTAssertFalse(controller.creator.hasParameterChanges)
                XCTAssertTrue(controller.creator.canSave); XCTAssertFalse(controller.creator.canApply)
                let after = try await c.store.snapshot(projectID: original.projectID, revisionID: original.id)
                XCTAssertEqual(before.digest, after.digest)
                try await controller.saveCreatorToLibrary()
                XCTAssertTrue(controller.creator.canApply)
                XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
            }
            XCTAssertTrue(c.route.requests.isEmpty, "Presets and validation are entirely local")
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }

    func testPresetRefusesUnknownCrossTemplateBusyAndCancelledActionsWithoutPartialEdits() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let original = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            let controller = panel.controller
            try await controller.selectCreatorProject(original.projectID)
            let initial = controller.creator.parameters
            XCTAssertThrowsError(try controller.applyCreatorPreset("missing", templateID: "stars-v2"))
            XCTAssertThrowsError(try controller.applyCreatorPreset("aurora", templateID: "gradient-v2"))
            controller.creator.isBusy = true
            XCTAssertThrowsError(try controller.applyCreatorPreset("quiet", templateID: "stars-v2"))
            controller.creator.isBusy = false
            let cancelled = Task { @MainActor in try controller.applyCreatorPreset("voyage", templateID: "stars-v2") }
            cancelled.cancel()
            do { try await cancelled.value; XCTFail("Cancelled edit applied") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(controller.creator.parameters, initial)
            XCTAssertEqual(controller.creator.selectedRevision?.id, original.id)
            XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty); XCTAssertTrue(c.route.requests.isEmpty)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }

    func testChoosingExistingPresetDoesNotInventChangesAndSliderEditsRemainLocal() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        let original = try await CreatorS14Fixtures.sealed(store: c.store, projectID: c.ticket.projectID)
        let preset = try CreatorTemplateCatalog.definition("stars-v2").presets[0]
        let revision = try await workspace.edit(project: original.projectID, revision: original.id, parameters: preset.parameters)
        let panel = try makeController(creatorWorkspace: workspace)
        do {
            let controller = panel.controller
            try await controller.selectCreatorProject(original.projectID)
            try controller.applyCreatorPreset(preset.id, templateID: "stars-v2")
            XCTAssertFalse(controller.creator.hasParameterChanges); XCTAssertTrue(controller.creator.canSave)
            try controller.setCreatorParameter("starDensity", value: .number(0.9))
            XCTAssertTrue(controller.creator.hasParameterChanges); XCTAssertFalse(controller.creator.canSave)
            try controller.applyCreatorPreset(preset.id, templateID: "stars-v2")
            XCTAssertFalse(controller.creator.hasParameterChanges)
            XCTAssertEqual(controller.creator.selectedRevision?.id, revision.id)
            XCTAssertTrue(c.route.requests.isEmpty); XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }

    private func canvas(_ surface: WebWallpaperPreviewSurface) async throws -> String {
        let value = try await surface.page.webView.callAsyncJavaScript("return document.querySelector('canvas').toDataURL();",
            arguments: [:], in: nil, contentWorld: .page)
        return try XCTUnwrap(value as? String)
    }
}
