import AppKit
import WebKit

/// Bounded validation in an unattached real WebKit page; no windows or desktop capture.
@MainActor
final class CreatorPosterService {
    typealias Snapshotter = @MainActor (WKWebView, WKSnapshotConfiguration, @escaping (Result<NSImage, Error>) -> Void) -> Void
    private let timeout: Duration
    private let configure: (WebWallpaperPreviewSurface) -> Void
    private let snapshotter: Snapshotter

    init(timeout: Duration = .seconds(5), configure: @escaping (WebWallpaperPreviewSurface) -> Void = { _ in },
         snapshotter: @escaping Snapshotter = { view, configuration, answer in
             view.takeSnapshot(with: configuration) { image, error in
                 if let image { answer(.success(image)) } else { answer(.failure(error ?? CreatorRuntimeFailure.invalidCapture)) }
             }
         }) {
        self.timeout = timeout; self.configure = configure; self.snapshotter = snapshotter
    }

    func capture(projectID: UUID, revisionID: UUID, store: CreatorRevisionStore) async throws -> CreatorRuntimeCapture {
        try Task.checkCancellation()
        guard timeout > .zero, timeout <= .seconds(5) else { throw CreatorRuntimeFailure.invalidCapture }
        let report = try await store.report(projectID: projectID, revisionID: revisionID)
        try report.context.runtime.validate()
        let preview = try await CreatorPreview.make(projectID: projectID, revisionID: revisionID, store: store)
        guard preview.snapshot.bundleVersion == 2, preview.snapshot.manifest?.packaging == .renderDraft,
              preview.snapshot.digest == report.bundleDigest else { preview.surface.stop(); throw CreatorRuntimeFailure.staleInput }
        let surface = preview.surface
        surface.view.setFrameSize(NSSize(width: report.context.width, height: report.context.height))
        surface.view.layoutSubtreeIfNeeded()
        surface.page.addUserScript(WKUserScript(source: Self.observer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configure(surface)
        let operation = Session(surface: surface, report: report, parameters: CreatorBundleManifest.parameters(preview.snapshot.specification),
                                timeout: timeout, snapshotter: snapshotter)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { Task { @MainActor in operation.finish(.failure(CreatorRuntimeFailure.cancelled)) } }
    }

    @MainActor private final class Session {
        let surface: WebWallpaperPreviewSurface
        let report: ValidationReport
        let parameters: [String: CreatorTemplateCatalog.Value]
        let timeout: Duration
        let snapshotter: Snapshotter
        var continuation: CheckedContinuation<CreatorRuntimeCapture, Error>?
        var deadline: Task<Void, Never>?
        var polling: Task<Void, Never>?
        var stopped = false
        var initialized = false
        init(surface: WebWallpaperPreviewSurface, report: ValidationReport, parameters: [String: CreatorTemplateCatalog.Value],
             timeout: Duration, snapshotter: @escaping Snapshotter) {
            self.surface = surface; self.report = report; self.parameters = parameters; self.timeout = timeout; self.snapshotter = snapshotter
        }
        func start(_ answer: CheckedContinuation<CreatorRuntimeCapture, Error>) {
            guard !stopped else { answer.resume(throwing: CreatorRuntimeFailure.cancelled); return }
            continuation = answer
            surface.onFailure = { [weak self] _ in
                guard let self else { return }
                self.finish(.failure(self.surface.page.creatorCodeFailure ?? .init(category: .runtime, runtimeReason: .pageFailed)))
            }
            deadline = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(.failure(CreatorRuntimeFailure.timeout))
            }
            polling = Task { [weak self] in
                guard let self else { return }
                do { try await surface.start(); poll() } catch { finish(.failure(CreatorRuntimeFailure.pageFailed)) }
            }
        }
        func poll() {
            guard !stopped else { return }
            guard surface.page.isLoaded else { again(); return }
            guard surface.page.webView.window == nil, surface.page.webView.url == CreatorWebResources.entryURL
            else { finish(.failure(CreatorRuntimeFailure.pageFailed)); return }
            if let code = surface.page.creatorCode { pollCode(code); return }
            surface.page.webView.callAsyncJavaScript(Self.status, arguments: ["expected": parameters.mapValues(\.json), "freeze": !initialized],
                in: nil, in: .page) { [weak self] result in
                guard let self, !stopped else { return }
                guard case .success(let value) = result, let state = value as? Int, state >= 0 else {
                    finish(.failure(CreatorRuntimeFailure.pageFailed)); return
                }
                if state == 1 { initialized = true; again() }
                else if state == 2 { snapshot() }
                else { again() }
            }
        }
        func pollCode(_ code: CreatorCodeSandbox) {
            guard code.ready, !code.stopped, code.failure == nil, let frame = code.frame else { again(); return }
            guard code.samples >= 2 else { again(); return }
            code.pause(true)
            surface.page.webView.callAsyncJavaScript("await document.fonts.ready; return document.readyState==='complete';",
                arguments: [:], in: frame, in: .page) { [weak self] result in
                guard let self, !stopped else { return }
                if case .success(let value) = result, value as? Bool == true { snapshot() }
                else { again() }
            }
        }
        func again() {
            polling = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                self?.poll()
            }
        }
        func snapshot() {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = surface.page.webView.bounds
            configuration.snapshotWidth = NSNumber(value: min(640, report.context.width))
            configuration.afterScreenUpdates = true
            snapshotter(surface.page.webView, configuration) { [weak self] result in
                guard let self, !stopped else { return }
                guard surface.page.isLoaded, surface.page.webView.window == nil else {
                    finish(.failure(CreatorRuntimeFailure.pageFailed)); return
                }
                if let code = surface.page.creatorCode {
                    guard code.ready, !code.stopped, code.failure == nil else { finish(.failure(CreatorRuntimeFailure.pageFailed)); return }
                    completeImage(result); return
                }
                surface.page.webView.callAsyncJavaScript(Self.status, arguments: ["expected": parameters.mapValues(\.json), "freeze": false],
                    in: nil, in: .page) { [weak self] status in
                    guard let self, !stopped else { return }
                    guard case .success(let value) = status, value as? Int == 2 else {
                        finish(.failure(CreatorRuntimeFailure.pageFailed)); return
                    }
                    completeImage(result)
                }
            }
        }
        func completeImage(_ result: Result<NSImage, Error>) {
            guard !stopped else { return }
            do {
                let image = try result.get()
                let encoded = try CreatorPosterImage.encode(image)
                let capture = CreatorRuntimeCapture(sourceReport: report, jpeg: encoded.jpeg, metrics: encoded.metrics)
                try capture.validate()
                finish(.success(capture))
            } catch { finish(.failure(CreatorRuntimeFailure.invalidCapture)) }
        }
        func finish(_ result: Result<CreatorRuntimeCapture, Error>) {
            guard !stopped else { return }
            stopped = true
            deadline?.cancel(); polling?.cancel()
            surface.stop()
            let answer = continuation; continuation = nil
            answer?.resume(with: result)
        }
        private static let status = """
          const s=window.__creatorValidation, c=document.querySelector('canvas');
          if(!s || s.errors>0) return -1;
          if(!s.general || s.paused===null || !document.fonts || document.fonts.status!=='loaded') return 0;
          if(!Object.entries(expected).every(([k,v])=>s.properties[k]?.value===v)) return 0;
          if(freeze) {
            wallpaperPropertyListener.setPaused(true); s.before=s.paints; dispatchEvent(new Event('resize')); return 1;
          }
          return s.paused===true && s.paints>s.before && c && c.width>0 && c.height>0 ? 2 : 0;
          """
    }

    private static let observer = """
      (()=>{
        const s={properties:{},general:false,paused:null,paints:0,before:0,errors:0};
        window.__creatorValidation=s;
        const descriptor=Object.getOwnPropertyDescriptor(window,'wallpaperPropertyListener');
        Object.defineProperty(window,'wallpaperPropertyListener',{...descriptor,set(listener){
          for(const name of ['applyUserProperties','applyGeneralProperties','setPaused']) {
            const original=listener[name];
            listener[name]=function(...args){
              const result=original?.apply(this,args);
              if(name==='applyUserProperties') Object.assign(s.properties,args[0]);
              if(name==='applyGeneralProperties') s.general=args[0]?.fps===30;
              if(name==='setPaused') s.paused=!!args[0];
              return result;
            };
          }
          descriptor.set.call(this,listener);
        }});
        const fill=CanvasRenderingContext2D.prototype.fillRect;
        CanvasRenderingContext2D.prototype.fillRect=function(...args){const value=fill.apply(this,args);s.paints++;return value;};
        const draw=WebGLRenderingContext.prototype.drawArrays;
        WebGLRenderingContext.prototype.drawArrays=function(...args){const value=draw.apply(this,args);s.paints++;return value;};
        for(const type of ['error','unhandledrejection','securitypolicyviolation']) addEventListener(type,()=>{s.errors++;});
      })();
      """
}
