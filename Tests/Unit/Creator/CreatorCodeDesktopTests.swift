import AppKit
import XCTest
@testable import WallpaperMachine

/// Production desktop host with inert surfaces/monitor: no window, global hook or desktop change.
@MainActor final class CreatorCodeDesktopTests: XCTestCase {
    final class Monitor: WebWallpaperPointerMonitoring {
        var isActive = false
        func setActive(_ active: Bool) { isActive = active }
    }
    final class Surface: WebWallpaperSurface {
        let page: WebWallpaperPage
        var frame: NSRect
        var posterLayer: CALayer? = CALayer()
        var windowNumber: Int { ObjectIdentifier(self).hashValue }
        init(_ frame: NSRect, _ page: WebWallpaperPage) { self.frame = frame; self.page = page; page.webView.setFrameSize(frame.size) }
        func setScreenFrame(_ frame: NSRect) { self.frame = frame; page.webView.setFrameSize(frame.size) }
        func present() {}
        func retire() {}
    }
    func testTwoRegisteredScreensHaveSeparateProcessesAndNoPointerMonitorWhilePausedOrAsleep() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorCodeWorkflowTests.output())])])
        let revision = try await workspace.generate(CreatorCodeWorkflowTests.request(c))
        let installed = try await workspace.publish(project: revision.projectID, revision: revision.sealed.id)
        let registry = c.root.appendingPathComponent("registry.json"), publication = c.root.appendingPathComponent("publication")
        let monitor = Monitor(), defaults = TemporaryDefaults.makeForCurrentTest().defaults
        var surfaces: [Surface] = []
        let host = WebWallpaperHost(fetch: { [] }, screens: { [(UInt32(7), NSRect(x: 0, y: 0, width: 320, height: 180)), (UInt32(8), NSRect(x: 320, y: 0, width: 256, height: 160))] },
            refreshRate: { $0 == 7 ? 60 : 144 }, imagePlacement: StillImagePlacementStore(defaults: defaults, library: c.root),
            pointerMonitor: monitor, inspectionEnabled: { false }, makeSurface: { frame, page in
                page.creatorSnapshotLoader = { try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry, publicationRoot: publication) }
                let surface = Surface(frame, page); surfaces.append(surface); return surface
            })
        defer { host.shutdown() }
        func descriptor(_ display: UInt32) -> BridgeWebWallpaper {
            .init(displayId: display, startupRevision: 1, displayKey: "fixture", audioSourceDisplayId: display,
                wallpaperId: installed.lastPathComponent, title: "Code", projectPath: installed.path, entryFile: "index.html",
                fps: 144, renderScale: 1, paused: false, volume: 0, muted: true, audioResponseEnabled: false,
                mediaIntegrationEnabled: false, propertiesJson: "{}")
        }
        var first = descriptor(7), second = descriptor(8)
        await host.apply([first, second])
        let deadline = ContinuousClock.now + .seconds(5)
        while !surfaces.allSatisfy({ $0.page.isLoaded }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(surfaces.count, 2); XCTAssertTrue(surfaces.allSatisfy { $0.page.isLoaded })
        XCTAssertNotEqual(surfaces.first?.page.creatorCode?.processID, surfaces.last?.page.creatorCode?.processID)
        XCTAssertTrue(monitor.isActive)
        for surface in surfaces { XCTAssertEqual(surface.page.pointerMoveInterval, 1.0 / 30, accuracy: 0.000001) }
        first.paused = true; second.paused = true
        await host.apply([first, second]); XCTAssertFalse(monitor.isActive)
        first.paused = false
        await host.apply([first, second]); XCTAssertTrue(monitor.isActive)
        host.setPresentationSuspended(true, forDisplay: 7); XCTAssertFalse(monitor.isActive)
        host.setPresentationSuspended(false, forDisplay: 7); XCTAssertTrue(monitor.isActive)
        host.setPresentationSuspended(true); XCTAssertFalse(monitor.isActive)
        host.setPresentationSuspended(false); XCTAssertTrue(monitor.isActive)
        host.shutdown(); XCTAssertFalse(monitor.isActive)
        XCTAssertTrue(surfaces.allSatisfy { $0.page.creatorCode == nil })
        XCTAssertEqual(c.route.requests.count, 1, "playback/resume never creates a model request")
    }
}
