import CryptoKit
import WebKit
import XCTest
@testable import WallpaperMachine

/// Native, unattached pages only. Real pixels, shader compilation and context restoration.
@MainActor final class CreatorWebGLTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-gl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func js(_ surface: WebWallpaperPreviewSurface, _ code: String) async throws -> Any? {
        try await surface.page.webView.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page)
    }
    func make(_ id: String, values: [String: CreatorTemplateCatalog.Value]? = nil, fallback: Bool = false) async throws -> WebWallpaperPreviewSurface {
        let store = CreatorDraftStore(root: root.appendingPathComponent(UUID().uuidString))
        let definition = try CreatorTemplateCatalog.definition(id)
        let url = try await store.create(definition.specification(parameters: values))
        let result = try await CreatorPreview.make(directory: url, store: store), surface = result.surface
        surface.view.setFrameSize(NSSize(width: 480, height: 270)); surface.view.layoutSubtreeIfNeeded()
        var source = CreatorTemplateRenderingTests.clockAndCounters
        if fallback { source += "\nconst get=HTMLCanvasElement.prototype.getContext;HTMLCanvasElement.prototype.getContext=function(k,...a){return k==='webgl'?null:get.call(this,k,...a)};" }
        surface.page.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        do {
            try await surface.start()
            let deadline = ContinuousClock.now + .seconds(10)
            while !surface.page.isLoaded && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(surface.page.isLoaded)
            _ = try await js(surface, "await __probe.waitFor(()=>__probe.paused===false&&__probe.general.fps===30&&Object.keys(__probe.properties).length>0);for(let i=0;i<11;i++)__probe.step(40);return true;")
            if !fallback {
                let available = try await js(surface, "return __creatorRenderer.contextAvailable;") as? Bool
                try XCTSkipUnless(available == true, "WebGL unavailable; fallback and native poster tests still run")
            }
            let observed1 = try await js(surface, "return __creatorRenderer.backend;") as? String
            XCTAssertEqual(observed1, fallback ? "fallback" : "webgl", "Shader failure must not hide behind fallback")
            XCTAssertNil(surface.page.webView.window)
            return surface
        } catch { surface.stop(); throw error }
    }
    func apply(_ values: [String: CreatorTemplateCatalog.Value], _ surface: WebWallpaperPreviewSurface) async throws {
        let data = try JSONSerialization.data(withJSONObject: values.mapValues { ["value": $0.json] }, options: [.sortedKeys])
        try surface.applyProperties(String(decoding: data, as: UTF8.self))
        _ = try await js(surface, "await new Promise(r=>setTimeout(r,40));__probe.step(40);return true;")
    }
    func pause(_ surface: WebWallpaperPreviewSurface) async throws {
        try surface.setPaused(true)
        _ = try await js(surface, "await __probe.waitFor(()=>__probe.paused===true);__probe.step(40);return true;")
    }
    func picture(_ surface: WebWallpaperPreviewSurface) async throws -> Data {
        let image = try await surface.page.webView.takeSnapshot(configuration: nil)
        return try CreatorPosterImage.encode(image).jpeg
    }
    func testAllParametersAndPresetPairsHaveVisibleEffectsWithoutChangingTheCatalog() async throws {
        for definition in CreatorTemplateCatalog.all {
            let surface = try await make(definition.id); defer { surface.stop() }
            try await pause(surface)
            for parameter in definition.parameters {
                try await apply(definition.defaults, surface)
                let low: CreatorTemplateCatalog.Value, high: CreatorTemplateCatalog.Value
                switch parameter.domain {
                case .number(let range, _, _):
                    low = .number(range.lowerBound)
                    high = .number(parameter.id.hasSuffix("Hue") ? 180 : parameter.id == "angle" ? 135 : range.upperBound)
                case .bool: low = .bool(false); high = .bool(true)
                case .choice(let choices): low = .choice(choices.first!.value); high = .choice(choices.last!.value)
                }
                try await apply([parameter.id: low], surface); let before = try await picture(surface)
                try await apply([parameter.id: high], surface); let after = try await picture(surface)
                XCTAssertNotEqual(before, after, "\(definition.id).\(parameter.id)")
            }
            try await apply(definition.presets[0].parameters, surface); let first = try await picture(surface)
            try await apply(definition.presets[1].parameters, surface); let second = try await picture(surface)
            XCTAssertNotEqual(first, second)
            let observed2 = try await js(surface, "return __probe.errors;") as? [String]
            XCTAssertEqual(observed2, [])
        }
    }
    func test144HzInputAndExtremeSizesStayInsideBudgetsAndStopWhenPaused() async throws {
        let surface = try await make("stars-v2"); defer { surface.stop() }
        for fps in [30, 10, 144, 0] {
            surface.page.applyGeneralProperties(fps: UInt32(fps))
            let frames = try await js(surface, "await new Promise(r=>setTimeout(r,40));const n=__creatorRenderer.frames;for(let i=0;i<144;i++)__probe.step(1000/144);return __creatorRenderer.frames-n;") as? Int ?? 999
            XCTAssertLessThanOrEqual(frames, min(fps == 0 ? 30 : fps, 30))
            XCTAssertGreaterThan(frames, 0)
        }
        for size in [NSSize(width: 3840, height: 2160), .init(width: 2560, height: 1600), .init(width: 10000, height: 8000), .init(width: 20000, height: 10)] {
            surface.view.setFrameSize(size); surface.view.layoutSubtreeIfNeeded()
            let count = try await js(surface, "dispatchEvent(new Event('resize'));__probe.step(40);return canvas.width*canvas.height;") as? Int ?? .max
            XCTAssertLessThanOrEqual(count, 2_073_600)
        }
        try await pause(surface)
        let stopped = try await js(surface, "const n=__creatorRenderer.frames;for(let i=0;i<144;i++)__probe.step(1000/144);return __creatorRenderer.frames-n;") as? Int
        XCTAssertEqual(stopped, 0)
        _ = try await js(surface, "dispatchEvent(new Event('pagehide'));return true;")
        let observed3 = try await js(surface, "const n=__creatorRenderer.frames;for(let i=0;i<144;i++)__probe.step(10);await new Promise(r=>setTimeout(r,100));return __creatorRenderer.frames-n;") as? Int
        XCTAssertEqual(observed3, 0)
    }
    func testMaximumClockFitsAllAnchorsAtHeterogeneousAspectRatios() async throws {
        let surface = try await make("clock-v2"); defer { surface.stop() }
        try await apply(["clockScale": .number(1.5), "showSeconds": .bool(true), "showDate": .bool(true)], surface)
        for size in [NSSize(width: 1920, height: 1080), .init(width: 1280, height: 800), .init(width: 3440, height: 1440), .init(width: 180, height: 320)] {
            surface.view.setFrameSize(size); surface.view.layoutSubtreeIfNeeded()
            for anchor in ["topLeft", "center", "bottomRight"] {
                try await apply(["clockAnchor": .choice(anchor)], surface)
                let rawRect = try await js(surface, "dispatchEvent(new Event('resize'));__probe.step(40);const r=document.getElementById('hud').getBoundingClientRect();return [r.left,r.top,r.right,r.bottom];") as? [Double]
                let rect = try XCTUnwrap(rawRect)
                XCTAssertGreaterThanOrEqual(rect[0], 11); XCTAssertGreaterThanOrEqual(rect[1], 11)
                XCTAssertLessThanOrEqual(rect[2], size.width-11); XCTAssertLessThanOrEqual(rect[3], size.height-11)
            }
        }
    }
    func testActualContextLossRestoresAndFallbackStillCreatesNativePoster() async throws {
        let surface = try await make("gradient-v2"); defer { surface.stop() }
        try await pause(surface)
        _ = try await picture(surface)
        _ = try await js(surface, "window.loss=canvas.getContext('webgl').getExtension('WEBGL_lose_context');loss.loseContext();await new Promise(r=>setTimeout(r,100));__probe.step(40);return true;")
        let observed4 = try await js(surface, "return __creatorRenderer.backend;") as? String
        XCTAssertEqual(observed4, "fallback")
        _ = try await picture(surface)
        _ = try await js(surface, "loss.restoreContext();await new Promise(r=>setTimeout(r,200));__probe.step(40);return true;")
        let observed5 = try await js(surface, "return __creatorRenderer.backend;") as? String
        XCTAssertEqual(observed5, "webgl")
        let observed6 = try await js(surface, "return __creatorRenderer.restored;") as? Int
        XCTAssertEqual(observed6, 1)
        _ = try await picture(surface)
        for definition in CreatorTemplateCatalog.all {
            let fallback = try await make(definition.id, fallback: true); defer { fallback.stop() }
            _ = try await picture(fallback)
            let observed7 = try await js(fallback, "return __probe.errors;") as? [String]
            XCTAssertEqual(observed7, [])
        }
    }
    func testInvalidPropertiesDoNotChangePixelsOrBudget() async throws {
        let surface = try await make("gradient-v2"); defer { surface.stop() }; try await pause(surface)
        let before = try await picture(surface)
        try await apply(["waveStrength": .number(100), "maxPixels": .number(1e9), "primaryHue": .choice("0")], surface)
        let observed8 = try await picture(surface)
        XCTAssertEqual(observed8, before)
    }
}
