import AppKit
import SwiftUI
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorMediaPanelTests: PanelTestCase {
    func testMediaControlsHotEditingAndVisionConsentStayLocal() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let panel = try makeController(creatorWorkspace: CreatorWorkspaceTests.workspace(c))
        do {
            let controller = panel.controller
            try await controller.recoverCreator()
            try await controller.openCreatorMaster("rain")
            XCTAssertEqual(controller.creator.engine, .hybridMedia)
            XCTAssertFalse(controller.creator.sendsThumbnail)
            try controller.setCreatorParameter("mediaExposure", value: .number(-0.5))
            XCTAssertTrue(controller.creator.canSave); XCTAssertTrue(controller.creator.canApply)
            XCTAssertTrue(controller.creator.hasParameterChanges)
            let host = NSHostingController(rootView: CreatorInspector().environment(controller).panelTheme(theme: controller.theme, locale: PanelLocale.shared))
            host.sizingOptions = []
            let size = host.sizeThatFits(in: NSSize(width: 320, height: 540))
            XCTAssertLessThanOrEqual(size.width, 321); XCTAssertNil(host.view.window)
            try await controller.setCreatorEngine(.scene2D)
            XCTAssertNil(controller.creator.selectedProjectID)
            XCTAssertFalse(controller.creator.sendsThumbnail)
            XCTAssertTrue(c.route.requests.isEmpty); XCTAssertTrue(panel.bridge.hostStartupCalls.isEmpty)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }
}
