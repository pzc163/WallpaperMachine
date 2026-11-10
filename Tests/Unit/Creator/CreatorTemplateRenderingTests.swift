import WebKit
import XCTest
@testable import WallpaperMachine

/// Pixel reads stay inside an unattached WKWebView; no window or desktop capture.
@MainActor
final class CreatorTemplateRenderingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func js(_ surface: WebWallpaperPreviewSurface, _ code: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await surface.page.webView.callAsyncJavaScript(code, arguments: arguments, in: nil, contentWorld: .page)
    }

    private func value<T>(_ surface: WebWallpaperPreviewSurface, _ code: String, as type: T.Type) async throws -> T {
        let result = try await js(surface, code)
        return try XCTUnwrap(result as? T)
    }

    private func make(_ definition: CreatorTemplateCatalog.Definition,
                      values: [String: CreatorTemplateCatalog.Value]? = nil, deterministic: Bool = true) async throws -> WebWallpaperPreviewSurface {
        let store = CreatorDraftStore(root: root.appendingPathComponent(UUID().uuidString))
        let directory = try await store.create(definition.specification(parameters: values))
        let result = try await CreatorPreview.make(directory: directory, store: store)
        let surface = result.surface
        surface.view.setFrameSize(NSSize(width: 320, height: 180))
        surface.view.layoutSubtreeIfNeeded()
        surface.page.addUserScript(WKUserScript(source: deterministic ? Self.clockAndCounters : "window.__probe={errors:[]};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        do {
            try await surface.start()
            let deadline = Date().addingTimeInterval(10)
            while !surface.page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard surface.page.isLoaded else { throw CreatorTemplate.Failure.invalidBundle }
            XCTAssertNil(surface.page.webView.window)
            XCTAssertEqual(surface.page.webView.url, CreatorWebResources.entryURL)
            if deterministic { _ = try await js(surface, "for(let i=0;i<11;i++) __probe.step(40); return true;") }
            return surface
        } catch { surface.stop(); throw error }
    }

    private func pause(_ surface: WebWallpaperPreviewSurface) async throws {
        try surface.setPaused(true)
        _ = try await js(surface, "await new Promise(r=>setTimeout(r,30)); __probe.step(40); return true;")
    }

    private func apply(_ values: [String: CreatorTemplateCatalog.Value], to surface: WebWallpaperPreviewSurface) async throws {
        let payload = values.mapValues { ["value": $0.json] }
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        try surface.applyProperties(String(decoding: data, as: UTF8.self))
        _ = try await js(surface, "await new Promise(r=>setTimeout(r,30)); __probe.step(40); return true;")
    }

    private func pixels(_ surface: WebWallpaperPreviewSurface) async throws -> [String: Any] {
        let result = try await js(surface, Self.readPixels)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testEveryParameterHasAnObservablePixelEffectAtFixedTime() async throws {
        for definition in CreatorTemplateCatalog.all {
            let surface = try await make(definition)
            defer { surface.stop() }
            try await pause(surface)
            for parameter in definition.parameters {
                try await apply(definition.defaults, to: surface)
                let low: CreatorTemplateCatalog.Value
                let high: CreatorTemplateCatalog.Value
                switch parameter.domain {
                case .number(let range, _, _): low = .number(range.lowerBound); high = .number(range.upperBound)
                case .bool: low = .bool(false); high = .bool(true)
                case .choice(let choices): low = .choice(choices.first!.value); high = .choice(choices.last!.value)
                }
                // A hue of 360 is intentionally the same color as 0.
                let distinctHigh: CreatorTemplateCatalog.Value = parameter.id.hasSuffix("Hue") ? .number(180) :
                    parameter.id == "angle" ? .number(135) : high
                try await apply([parameter.id: low], to: surface)
                let before = try await pixels(surface)
                try await apply([parameter.id: distinctHigh], to: surface)
                let after = try await pixels(surface)
                XCTAssertNotEqual(before["hash"] as? String, after["hash"] as? String, "\(definition.id).\(parameter.id) has no pixel effect")
                XCTAssertEqual(after["opaque"] as? Bool, true)
            }
            let errors = try await js(surface, "return __probe.errors;") as? [String]
            XCTAssertEqual(errors, [])
        }
    }

    func testPresetPairsDifferVisiblyAndSeedsReproducePixels() async throws {
        for definition in CreatorTemplateCatalog.all {
            var samples: [[Double]] = []
            var hashes: [String] = []
            for preset in definition.presets + [definition.presets[0]] {
                let surface = try await make(definition, values: preset.parameters)
                defer { surface.stop() }
                try await pause(surface)
                let result = try await pixels(surface)
                samples.append(try XCTUnwrap(result["samples"] as? [Double]))
                hashes.append(try XCTUnwrap(result["hash"] as? String))
            }
            XCTAssertEqual(hashes[0], hashes[2], "Same seed, clock, viewport and parameters must reproduce pixels")
            let difference = zip(samples[0], samples[1]).reduce(0.0) { $0 + abs($1.0-$1.1) } / Double(samples[0].count)
            XCTAssertGreaterThan(difference, 5, "\(definition.id): preset color/layout difference is too small")
        }
    }

    func testMinimumDefaultMaximumAndAllEnumChoicesPaintWithoutErrors() async throws {
        for definition in CreatorTemplateCatalog.all {
            let surface = try await make(definition)
            defer { surface.stop() }
            try await pause(surface)
            for maximum in [false, true] {
                var values = definition.defaults
                for parameter in definition.parameters {
                    switch parameter.domain {
                    case .number(let range, _, _): values[parameter.id] = .number(maximum ? range.upperBound : range.lowerBound)
                    case .bool: values[parameter.id] = .bool(maximum)
                    case .choice(let choices): values[parameter.id] = .choice((maximum ? choices.last! : choices.first!).value)
                    }
                }
                try await apply(values, to: surface)
                let result = try await pixels(surface)
                XCTAssertEqual(result["opaque"] as? Bool, true)
                XCTAssertEqual(result["errors"] as? [String], [])
            }
            try await apply(definition.defaults, to: surface)
            for parameter in definition.parameters {
                if case .choice(let choices) = parameter.domain {
                    var signatures = Set<String>()
                    for choice in choices {
                        try await apply([parameter.id: .choice(choice.value)], to: surface)
                        let result = try await pixels(surface)
                        signatures.insert(try XCTUnwrap(result["hash"] as? String))
                        XCTAssertEqual(result["errors"] as? [String], [])
                    }
                    XCTAssertEqual(signatures.count, choices.count, "\(parameter.id): enum choices must have distinct renderings")
                }
            }
        }
    }

    func testCombinedWorstCaseUsesBoundedParticlesTrailsPixelsAndFrameRate() async throws {
        let definition = try CreatorTemplateCatalog.definition("stars-v2")
        var values = definition.defaults
        for key in ["starDensity", "starSizeSpread", "trailLength"] { values[key] = .number(1) }
        values["parallaxLayers"] = .number(4); values["meteorRate"] = .number(6)
        values["motionSpeed"] = .number(2); values["twinkleHz"] = .number(3)
        let surface = try await make(definition, values: values)
        defer { surface.stop() }
        let expected = try definition.allocation(for: values)
        let counts = try await value(surface, "__probe.reset(); __probe.step(40); return __probe.counts;", as: [String: Int].self)
        XCTAssertEqual(counts["arcs"], expected.particles)
        XCTAssertLessThanOrEqual(counts["strokes"] ?? .max, expected.trailSegments + definition.budget.maxMeteors)
        XCTAssertGreaterThanOrEqual(counts["strokes"] ?? 0, expected.trailSegments)

        let pacing = try await value(surface, "__probe.reset(); for(let i=0;i<120;i++) __probe.step(1000/120); return __probe.counts.frames;", as: Int.self)
        XCTAssertLessThanOrEqual(pacing, definition.budget.maxFPS+1)
        XCTAssertGreaterThanOrEqual(pacing, definition.budget.maxFPS-1)
        surface.page.applyGeneralProperties(fps: 10)
        let slower = try await value(surface, "await new Promise(r=>setTimeout(r,30)); __probe.reset(); for(let i=0;i<120;i++) __probe.step(1000/120); return __probe.counts.frames;", as: Int.self)
        XCTAssertLessThanOrEqual(slower, 11)
        XCTAssertGreaterThanOrEqual(slower, 9)
        for requestedFPS in [UInt32(240), 0] {
            // The existing host uses zero for no limit; the template still caps work.
            surface.page.applyGeneralProperties(fps: requestedFPS)
            let capped = try await value(surface, "await new Promise(r=>setTimeout(r,30)); __probe.reset(); for(let i=0;i<120;i++) __probe.step(1000/120); return __probe.counts.frames;", as: Int.self)
            XCTAssertLessThanOrEqual(capped, definition.budget.maxFPS+1)
            XCTAssertGreaterThanOrEqual(capped, definition.budget.maxFPS-1)
        }

        for size in [NSSize(width: 10_000, height: 8_000), NSSize(width: 20_000, height: 10), NSSize(width: 10, height: 20_000)] {
            surface.view.setFrameSize(size)
            surface.view.layoutSubtreeIfNeeded()
            let dimensions = try await value(surface, "dispatchEvent(new Event('resize')); __probe.step(40); return [canvas.width,canvas.height,innerWidth,innerHeight,devicePixelRatio];", as: [Double].self)
            XCTAssertLessThanOrEqual(dimensions[0]*dimensions[1], Double(definition.budget.maxPixels))
            XCTAssertLessThanOrEqual(max(dimensions[0], dimensions[1]), Double(definition.budget.maxDimension))
            XCTAssertGreaterThan(min(dimensions[0], dimensions[1]), 0)
            XCTAssertEqual(dimensions[2], size.width, accuracy: 1)
            let scale = min(dimensions[4], Double(definition.budget.maxDeviceScale),
                            Double(definition.budget.maxDimension)/size.width,
                            Double(definition.budget.maxDimension)/size.height,
                            sqrt(Double(definition.budget.maxPixels)/(size.width*size.height)))
            XCTAssertEqual(dimensions[0], max(1, floor(size.width*scale)), accuracy: 1)
            XCTAssertEqual(dimensions[1], max(1, floor(size.height*scale)), accuracy: 1)
        }
    }

    func testMeteorCadenceDoesNotMultiplyWithLayersOrDensity() async throws {
        let definition = try CreatorTemplateCatalog.definition("stars-v2")
        for rate in [0, 1, 6] {
            var values = definition.defaults
            values["starDensity"] = .number(0); values["trailLength"] = .number(0)
            values["clockVisible"] = .bool(false); values["parallaxLayers"] = .number(4)
            values["meteorRate"] = .number(Double(rate))
            let surface = try await make(definition, values: values)
            defer { surface.stop() }
            let observed: [String: Int] = try await value(surface, """
              let previous=__probe.counts.strokes>0, starts=0, maximum=0;
              for(let i=0;i<600;i++) {
                __probe.reset(); __probe.step(100);
                const active=__probe.counts.strokes>0;
                if(active && !previous) starts++;
                previous=active; maximum=Math.max(maximum,__probe.counts.strokes);
              }
              return {starts,maximum};
              """, as: [String: Int].self)
            XCTAssertEqual(observed["starts"], rate)
            XCTAssertLessThanOrEqual(observed["maximum"] ?? .max, definition.budget.maxMeteors)
        }
    }

    func testPausedEditsCoalesceAndPagehideCancelsPendingWork() async throws {
        let surface = try await make(CreatorTemplateCatalog.definition("gradient-v2"))
        defer { surface.stop() }
        try await pause(surface)
        let counts: [Int] = try await value(surface, """
          __probe.reset();
          for(let i=0;i<100;i++) wallpaperPropertyListener.applyUserProperties({primaryHue:{value:i}});
          const immediate=__probe.counts.frames;
          __probe.step(40); await new Promise(r=>setTimeout(r,80));
          const coalesced=__probe.counts.frames;
          wallpaperPropertyListener.applyUserProperties({primaryHue:{value:200}});
          dispatchEvent(new Event('pagehide')); __probe.reset();
          for(let i=0;i<10;i++) __probe.step(40);
          await new Promise(r=>setTimeout(r,80));
          return [immediate,coalesced,__probe.counts.frames];
          """, as: [Int].self)
        XCTAssertLessThanOrEqual(counts[0], 1)
        XCTAssertEqual(counts[1], 2, "A burst paints once immediately and once with its final values")
        XCTAssertEqual(counts[2], 0, "Neither queued frames nor dirty timers survive pagehide")
    }

    func testRuntimePropertiesCannotExpandNativeCatalogOrBudgets() async throws {
        let definition = try CreatorTemplateCatalog.definition("stars-v2")
        let surface = try await make(definition)
        defer { surface.stop() }
        try await pause(surface)
        let before = try await pixels(surface)
        let invalid: [String: CreatorTemplateCatalog.Value] = [
            "starDensity": .number(1_000_000), "parallaxLayers": .number(2.5), "trailLength": .choice("1"),
            "clockVisible": .number(1), "clockAnchor": .choice("<script>"), "maxParticles": .number(1_000_000),
        ]
        try await apply(invalid, to: surface)
        let after = try await pixels(surface)
        XCTAssertEqual(before["hash"] as? String, after["hash"] as? String)
        XCTAssertEqual(after["errors"] as? [String], [])
    }

    func testPauseResizeResumeAndStopAcrossEveryTemplate() async throws {
        for definition in CreatorTemplateCatalog.all {
            let surface = try await make(definition)
            defer { surface.stop() }
            try await pause(surface)
            let before = try await pixels(surface)
            let pausedFrames = try await js(surface, "__probe.reset(); for(let i=0;i<60;i++) __probe.step(40); return __probe.counts.frames;") as? Int
            XCTAssertEqual(pausedFrames, 0)
            let paused = try await pixels(surface)
            XCTAssertEqual(before["hash"] as? String, paused["hash"] as? String)
            try await apply(["primaryHue": .number(40)], to: surface)
            let edited = try await pixels(surface)
            XCTAssertNotEqual(paused["hash"] as? String, edited["hash"] as? String)
            surface.view.setFrameSize(NSSize(width: 180, height: 320))
            surface.view.layoutSubtreeIfNeeded()
            // The host detaches a paused page. Its container size is applied on resume.
            try surface.setPaused(false)
            let portrait = try await js(surface, "await new Promise(r=>setTimeout(r,30)); dispatchEvent(new Event('resize')); __probe.step(40); return canvas.height>canvas.width;") as? Bool
            XCTAssertEqual(portrait, true)
            let frames = try await js(surface, "await new Promise(r=>setTimeout(r,30)); __probe.reset(); for(let i=0;i<12;i++) __probe.step(40); return __probe.counts.frames;") as? Int
            XCTAssertGreaterThan(frames ?? 0, 1)
            surface.stop()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(surface.page.isLoaded)
            XCTAssertNil(surface.page.webView.superview)
            let stopped = try await js(surface, "return document.querySelector('canvas')===null;") as? Bool
            XCTAssertEqual(stopped, true)
            do { try await surface.start(); XCTFail("Stopped preview restarted") } catch is CancellationError {}
        }
    }

    func testUnattachedWebKitPaintsAndEditsWithoutTestClock() async throws {
        for definition in CreatorTemplateCatalog.all {
            let surface = try await make(definition, deterministic: false)
            defer { surface.stop() }
            let first = try await pixels(surface)
            XCTAssertEqual(first["opaque"] as? Bool, true)
            let data = try JSONSerialization.data(withJSONObject: ["primaryHue": ["value": 40]])
            try surface.applyProperties(String(decoding: data, as: UTF8.self))
            try await Task.sleep(for: .milliseconds(150))
            let edited = try await pixels(surface)
            XCTAssertNotEqual(first["hash"] as? String, edited["hash"] as? String)
            try surface.setPaused(true)
            try await Task.sleep(for: .milliseconds(100))
            let paused = try await pixels(surface)
            try await Task.sleep(for: .milliseconds(150))
            let still = try await pixels(surface)
            XCTAssertEqual(paused["hash"] as? String, still["hash"] as? String)
            XCTAssertEqual(still["opaque"] as? Bool, true)
            XCTAssertEqual(still["errors"] as? [String], [])
        }
    }

    private static let readPixels = """
      const c=document.querySelector('canvas'), bytes=c.getContext('2d').getImageData(0,0,c.width,c.height).data;
      let hash=2166136261, opaque=true; const samples=[];
      for(let i=0;i<bytes.length;i++) { hash=Math.imul(hash^bytes[i],16777619)>>>0; if(i%4===3 && bytes[i]!==255) opaque=false; }
      for(let y=0;y<12;y++) for(let x=0;x<20;x++) {
        const i=(Math.floor((y+0.5)*c.height/12)*c.width+Math.floor((x+0.5)*c.width/20))*4;
        samples.push(bytes[i],bytes[i+1],bytes[i+2]);
      }
      return {hash:String(hash),opaque,samples,errors:__probe.errors};
      """

    private static let clockAndCounters = """
      (()=>{
        const NativeDate=Date, fixed=new NativeDate(2026,0,2,13,4,5).getTime();
        window.Date=class extends NativeDate { constructor(...args) { super(...(args.length?args:[fixed])); } static now(){return fixed;} };
        let now=0, next=0; const pending=new Map();
        Object.defineProperty(performance,'now',{value:()=>now});
        const probe={counts:{frames:0,arcs:0,strokes:0},errors:[],reset(){this.counts={frames:0,arcs:0,strokes:0};},
          step(delta){now+=delta;const batch=[...pending.values()];pending.clear();for(const callback of batch)callback(now);}};
        window.__probe=probe;
        window.requestAnimationFrame=callback=>{pending.set(++next,callback);return next;};
        window.cancelAnimationFrame=id=>pending.delete(id);
        for(const [method,key] of [['createLinearGradient','frames'],['arc','arcs'],['stroke','strokes']]) {
          const original=CanvasRenderingContext2D.prototype[method];
          CanvasRenderingContext2D.prototype[method]=function(...args){probe.counts[key]++;return original.apply(this,args);};
        }
        addEventListener('error',event=>probe.errors.push(event.message));
        addEventListener('unhandledrejection',event=>probe.errors.push(String(event.reason)));
      })();
      """
}
