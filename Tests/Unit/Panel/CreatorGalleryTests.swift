import AppKit
import SwiftUI
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorGalleryTests: PanelTestCase {
    func testDefaultEngineMasterActionsAndParameterBoundaryWithoutModelOrDesktop() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            let controller = panel.controller
            try await controller.recoverCreator()
            XCTAssertEqual(controller.creator.mode, .code); XCTAssertEqual(controller.creator.engine, .shaderGLSL)
            XCTAssertEqual(controller.creator.masters.count, 9)
            try await controller.openCreatorMaster("ink")
            let first = try XCTUnwrap(controller.creator.selectedRevision)
            XCTAssertTrue(controller.creator.canSave); XCTAssertTrue(controller.creator.canApply)
            XCTAssertFalse(controller.creator.showsGallery); XCTAssertNil(controller.creator.embedded.view)
            try controller.setCreatorParameter("glow", value: .number(2))
            XCTAssertTrue(controller.creator.hasParameterChanges); XCTAssertTrue(controller.creator.canSave)
            try await controller.validateCreatorParameters()
            XCTAssertNotEqual(controller.creator.selectedRevision?.id, first.id); XCTAssertTrue(controller.creator.canSave)
            try await controller.setCreatorEngine(.three3D)
            XCTAssertNil(controller.creator.selectedProjectID); XCTAssertTrue(controller.creator.showsGallery)
            try await controller.selectCreatorProject(first.projectID)
            XCTAssertEqual(controller.creator.engine, .shaderGLSL)
            do { try await controller.setCreatorEngine(.audioReactive); XCTFail("Future engine exposed") } catch {}
            XCTAssertEqual(controller.creator.engine, .shaderGLSL)
            XCTAssertTrue(c.route.requests.isEmpty); XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
    func testGalleryNarrowLayoutAndEveryMasterParameterLocalizedInSixLanguages() async throws {
        try await withPanel { panel in
            let controller = panel.controller
            try await controller.recoverCreator()
            defer { PanelLocale.shared.bind(to: .testHost) }
            for language in AppLanguage.supported {
                PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language.tag]))
                for engine in CreatorEngine.allCases.filter(\.available) {
                    controller.creator.engine = engine
                    let host = NSHostingController(rootView: CreatorMasterGallery().environment(controller).panelTheme(theme: controller.theme, locale: PanelLocale.shared))
                    host.sizingOptions = []
                    let size = host.sizeThatFits(in: NSSize(width: 320, height: 560))
                    XCTAssertLessThanOrEqual(size.width, 321); XCTAssertTrue(size.height.isFinite); XCTAssertNil(host.view.window)
                    XCTAssertFalse(CreatorEngineLabels.title(engine).isEmpty)
                }
                let bundle = try XCTUnwrap(Bundle.main.url(forResource: language.tag, withExtension: "lproj"))
                let localized = try XCTUnwrap(Bundle(url: bundle))
                for master in controller.creator.masters {
                    for key in [master.title] + master.parameters.parameters.map(\.label) {
                        XCTAssertNotEqual(localized.localizedString(forKey: key, value: language.tag == "en" ? key : "missing", table: nil), "missing", language.tag + ": " + key)
                    }
                }
            }
        }
    }
}
