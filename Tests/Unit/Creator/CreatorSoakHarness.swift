import WebKit
import XCTest
@testable import WallpaperMachine

/// Real offscreen pages held for the entire interval. No windows, model or GPU attribution.
@MainActor
enum CreatorSoakHarness {
    static func executionAllowance(duration: TimeInterval) -> TimeInterval {
        max(duration + 600, 2400)
    }

    struct Sample: Codable {
        let seconds: Double
        let template: String
        let responsive: Bool
        let paused: Bool
        let width: Int
        let height: Int
        let paints: Int
        let externalAttempts: Int
        let processTerminations: Int
        let hostFootprintBytes: UInt64?
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let requestedSeconds: Double
        let intervalSeconds: Double
        let environment: [String: String]
        var elapsedSeconds = 0.0
        var passed = false
        var failure: String?
        var stoppedPages = 0
        var hostBaselineBytes: UInt64?
        var hostPeakBytes: UInt64?
        var hostFinalBytes: UInt64?
        var hostAfterStopBytes: UInt64?
        var hostDeltaBytes: Int64?
        var hostPeakGrowthBytes: UInt64?
        let memoryVerdict = "observed only; no calibrated per-wallpaper growth threshold; no GPU utilization estimate"
        var samples: [Sample] = []
        var completedThirtyMinutes = false
        let memoryScope = "rusage_info_v4.ri_phys_footprint of test host; excludes separate WebContent/GPU processes; not per wallpaper"
        let livenessScope = "bounded native JavaScript round trip + WebKit process-termination delegate; no OS process ID claim"
        let renderScope = "unattached WKWebView; periodic native resize forces a paint; rAF may be throttled; not desktop FPS or energy"
    }
    @MainActor private final class Entry {
        let template: String
        let surface: WebWallpaperPreviewSurface
        var terminations = 0
        var paints = 0
        init(_ template: String, _ surface: WebWallpaperPreviewSurface) {
            self.template = template; self.surface = surface
            surface.page.onContentProcessTermination = { [weak self] in self?.terminations += 1 }
        }
    }
    static func run(duration: Double, interval: Double,
                    configured: (WebWallpaperPreviewSurface) -> Void = { _ in }) async -> Report {
        var report = Report(requestedSeconds: duration, intervalSeconds: interval, environment: CreatorBenchmarkHarness.environment())
        guard duration.isFinite, interval.isFinite, (0.05...86_400).contains(duration),
              (0.01...60).contains(interval), interval <= duration, duration / interval <= 10_000 else {
            report.failure = "invalidConfiguration"; return report
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-soak-" + UUID().uuidString)
        var entries: [Entry] = []
        var started: ContinuousClock.Instant?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
            let registry = CreatorRuntimeRegistry(url: root.appendingPathComponent("registry.json"))
            let journal = root.appendingPathComponent("Publication"), library = root.appendingPathComponent("Library")
            let publisher = CreatorPublisher(root: journal, library: library, registry: registry)
            for definition in CreatorTemplateCatalog.all {
                try Task.checkCancellation()
                let sealed = try await CreatorS14Fixtures.sealed(store: store, template: definition.id)
                let installed = try await publisher.publish(projectID: sealed.projectID, revisionID: sealed.id, store: store)
                // Fresh installed-package read; no model client or persisted credential store exists.
                let snapshot = try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry.url, publicationRoot: journal)
                let properties = try definition.properties(for: snapshot.specification.parameters!)
                let request = try WallpaperPreviewRequest(.init(wallpaperId: snapshot.wallpaperID, title: "Soak", kind: .webpage,
                    projectPath: installed.path, entryFile: "index.html", assetsPath: installed.path,
                    propertiesJson: String(decoding: JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys]), as: UTF8.self),
                    fps: 30, scalingMode: .fill, scalingFactor: 1, volume: 0, engineOptions: nil, lutPath: nil, sceneQuality: .wallpaperEngineDefault))
                let surface = WebWallpaperPreviewSurface(request: request, generation: 0, inspectable: false)
                surface.page.creatorSnapshotLoader = {
                    try CreatorRuntimeRegistry.readForPlayback(installed, registryURL: registry.url, publicationRoot: journal)
                }
                surface.view.setFrameSize(NSSize(width: 1920, height: 1080))
                surface.view.layoutSubtreeIfNeeded()
                surface.page.addUserScript(WKUserScript(source: observer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                let entry = Entry(definition.id, surface); entries.append(entry)
                configured(surface)
                try await surface.start()
                let deadline = ContinuousClock.now + .seconds(5)
                while !surface.page.isLoaded && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                guard surface.page.isLoaded, surface.page.webView.window == nil else { throw CreatorRuntimeFailure.pageFailed }
                _ = try await settled(surface, paused: false)
            }
            report.hostBaselineBytes = ProcessFootprint.current()
            let start = ContinuousClock.now; started = start
            var tick = 0
            repeat {
                try Task.checkCancellation()
                let paused = tick % 2 == 1
                let sizes = [(1920, 1080), (1920, 1200), (1080, 1920)]
                let size = sizes[tick % sizes.count]
                for entry in entries {
                    let surface = entry.surface
                    try surface.setPaused(paused)
                    surface.view.setFrameSize(NSSize(width: size.0, height: size.1)); surface.view.layoutSubtreeIfNeeded()
                    _ = try await evaluate(surface.page.webView, "dispatchEvent(new Event('resize')); true")
                    let state = try await settled(surface, paused: paused, minimumPaints: entry.paints)
                    entry.paints = state["paints"] as? Int ?? 0
                    let memory = ProcessFootprint.current()
                    if let memory { report.hostPeakBytes = max(report.hostPeakBytes ?? memory, memory) }
                    report.samples.append(Sample(seconds: seconds(start), template: entry.template, responsive: true, paused: paused,
                        width: size.0, height: size.1, paints: state["paints"] as? Int ?? 0, externalAttempts: state["external"] as? Int ?? -1,
                        processTerminations: entry.terminations, hostFootprintBytes: memory))
                    guard surface.page.isLoaded, surface.page.webView.url == CreatorWebResources.entryURL,
                          state["errors"] as? Int == 0, state["external"] as? Int == 0,
                          state["opaque"] as? Bool == true, entry.terminations == 0 else { throw CreatorRuntimeFailure.pageFailed }
                }
                tick += 1
                let remaining = duration - seconds(start)
                if remaining <= 0 { break }
                try await Task.sleep(for: .seconds(min(interval, remaining)))
            } while true
            report.passed = true
        } catch {
            report.failure = Task.isCancelled || error is CancellationError ? "cancelled" : CreatorRepairIssue.from(error).description
        }
        if let started { report.elapsedSeconds = seconds(started) }
        report.hostFinalBytes = ProcessFootprint.current()
        for entry in entries { entry.surface.stop(); report.stoppedPages += 1 }
        report.hostAfterStopBytes = ProcessFootprint.current()
        if let baseline = report.hostBaselineBytes, let final = report.hostFinalBytes {
            report.hostDeltaBytes = Int64(final) - Int64(baseline)
        }
        if let baseline = report.hostBaselineBytes, let peak = report.hostPeakBytes {
            report.hostPeakGrowthBytes = peak > baseline ? peak - baseline : 0
        }
        report.completedThirtyMinutes = report.passed && duration >= 1800 && report.elapsedSeconds >= duration
        try? FileManager.default.removeItem(at: root)
        return report
    }
    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private static func settled(_ surface: WebWallpaperPreviewSurface, paused: Bool, minimumPaints: Int = 0) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            let value = try await evaluate(surface.page.webView, """
                (()=>{const s=window.__creatorSoak,c=document.querySelector('canvas');
                if(!s||!c||!s.general||!s.properties) return {};
                return {...s,opaque:c.width>0&&c.height>0&&c.getContext('2d').getImageData(c.width>>1,c.height>>1,1,1).data[3]>0};})()
                """) as? [String: Any] ?? [:]
            if value["paused"] as? Bool == paused, (value["paints"] as? Int ?? 0) > minimumPaints { return value }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw CreatorRuntimeFailure.timeout
    }
    /// Timeout lives in Swift and resumes the caller even if WebKit never calls back.
    static func evaluate(_ view: WKWebView, _ script: String, timeout: Duration = .seconds(5)) async throws -> Any? {
        try await bounded(timeout: timeout) { completion in
            view.evaluateJavaScript(script, completionHandler: completion)
        }
    }
    static func bounded(timeout: Duration, operation: (@escaping @MainActor @Sendable (Any?, Error?) -> Void) -> Void) async throws -> Any? {
        let call = Evaluation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { answer in
                call.answer = answer
                call.timer = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    call.finish(.failure(CreatorRuntimeFailure.timeout))
                }
                operation { value, error in
                    call.finish(error == nil ? .success(value) : .failure(CreatorRuntimeFailure.pageFailed))
                }
            }
        } onCancel: { Task { @MainActor in call.finish(.failure(CancellationError())) } }
    }
    @MainActor private final class Evaluation {
        var answer: CheckedContinuation<Any?, Error>?
        var timer: Task<Void, Never>?
        func finish(_ result: Result<Any?, Error>) {
            timer?.cancel(); timer = nil
            let previous = answer; answer = nil; previous?.resume(with: result)
        }
    }
    static let observer = """
      (()=>{
        const s={errors:0,external:0,paints:0,paused:null,general:false,properties:false};window.__creatorSoak=s;
        const d=Object.getOwnPropertyDescriptor(window,'wallpaperPropertyListener');
        Object.defineProperty(window,'wallpaperPropertyListener',{...d,set(l){
          for(const name of ['applyUserProperties','applyGeneralProperties','setPaused']) {
            const f=l[name];l[name]=function(...a){const r=f?.apply(this,a);
              if(name==='setPaused')s.paused=!!a[0];if(name==='applyGeneralProperties')s.general=true;
              if(name==='applyUserProperties')s.properties=true;return r;};
          }d.set.call(this,l);
        }});
        const fill=CanvasRenderingContext2D.prototype.fillRect;
        CanvasRenderingContext2D.prototype.fillRect=function(...a){s.paints++;return fill.apply(this,a)};
        const external=u=>/^https?:|^wss?:|^ftp:/i.test(String(u));
        const count=u=>{if(external(u))s.external++};
        const fetch=window.fetch;window.fetch=function(u,...a){count(u?.url||u);return fetch.call(this,u,...a)};
        const open=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u,...a){count(u);return open.call(this,m,u,...a)};
        for(const key of ['WebSocket','EventSource','Worker','SharedWorker'])if(window[key]){
          const original=window[key];window[key]=new Proxy(original,{construct(t,a){count(a[0]);return Reflect.construct(t,a)}});
        }
        const beacon=navigator.sendBeacon.bind(navigator);navigator.sendBeacon=(u,...a)=>{count(u);return beacon(u,...a)};
        const visit=n=>{if(n?.nodeType!==1)return;for(const key of ['src','href','poster','data'])count(n.getAttribute(key));
          for(const child of n.querySelectorAll('[src],[href],[poster],[data]'))for(const key of ['src','href','poster','data'])count(child.getAttribute(key))};
        new MutationObserver(ms=>ms.forEach(m=>{if(m.type==='attributes')count(m.target.getAttribute(m.attributeName));else m.addedNodes.forEach(visit)}))
          .observe(document,{subtree:true,childList:true,attributes:true,attributeFilter:['src','href','poster','data']});
        new PerformanceObserver(list=>list.getEntries().forEach(e=>count(e.name))).observe({type:'resource',buffered:true});
        addEventListener('securitypolicyviolation',e=>{count(e.blockedURI);s.errors++});
        for(const type of ['error','unhandledrejection'])addEventListener(type,()=>s.errors++);
      })();
      """
}
