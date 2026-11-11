import Foundation
import WebKit

/// Native-owned container, opaque sandbox child, isolated diagnostics and external deadlines.
/// Used identically for validation, preview and registered desktop playback.
@MainActor final class CreatorCodeSandbox: NSObject, WKScriptMessageHandler, WKDownloadDelegate {
    static let handler = "creatorCodeHealth"
    static let policy = "default-src 'none'; script-src 'unsafe-inline' wm-lib:; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
    static let container = """
    <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' wm-lib:; style-src 'unsafe-inline'; frame-src about:; child-src about:; connect-src 'none'; base-uri 'none'; form-action 'none'"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}iframe{border:0;width:100%;height:100%;display:block}</style><iframe id="creator-code" sandbox="allow-scripts" allow="camera 'none'; microphone 'none'; geolocation 'none'; display-capture 'none'; clipboard-read 'none'; clipboard-write 'none'; fullscreen 'none'; payment 'none'" referrerpolicy="no-referrer"></iframe>
    """
    let view: WKWebView
    private(set) var frame: WKFrameInfo?
    private(set) var processID: pid_t?
    private(set) var failure: CreatorRepairIssue?
    private(set) var stopped = false
    private(set) var ready = false
    private(set) var samples = 0
    var onReady: (() -> Void)?
    var onFailure: ((CreatorRepairIssue) -> Void)?
    private var monitor: Task<Void, Never>?
    private var pendingSince: ContinuousClock.Instant?
    private let timeout: Duration
    private let interval: Duration
    private let memoryLimit: UInt64
    private var epoch = UUID()
    private var highCPU = 0
    private var checking = false
    private var hostSuspended = false
    private var playbackPaused = false
    private var previousUsage: (clock: ContinuousClock.Instant, cpu: UInt64)?
    init(view: WKWebView, timeout: Duration = .seconds(2), interval: Duration = .milliseconds(250), memoryLimit: UInt64 = 512 * 1024 * 1024) {
        self.view = view; self.timeout = timeout; self.interval = interval; self.memoryLimit = min(512 * 1024 * 1024, max(64 * 1024 * 1024, memoryLimit))
        super.init()
        CreatorCodeProcess.observe(view)
        view.configuration.userContentController.addUserScript(WKUserScript(source: CreatorCodeSDK.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        view.configuration.userContentController.add(self, contentWorld: .defaultClient, name: Self.handler)
        view.configuration.userContentController.addUserScript(WKUserScript(source: Self.observer,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
    }
    func start(source: String) throws {
        guard !stopped, monitor == nil, CreatorCodeProcess.supported else { throw CreatorRuntimeFailure.pageFailed }
        frame = nil
        processID = try CreatorCodeProcess.claim(view)
        pendingSince = .now
        let epoch = epoch
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.epoch == epoch, !self.stopped else { return }
                self.tick()
                do { try await Task.sleep(for: self.interval) } catch { return }
            }
        }
        let html = "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"" + Self.policy + "\">" + source
        view.callAsyncJavaScript("document.getElementById('creator-code').srcdoc=html;", arguments: ["html": html], in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.fail(.init(category: .runtime, runtimeReason: .pageFailed)) }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !stopped, processID != nil, !message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.absoluteString == "about:srcdoc" else { return }
        guard message.name == Self.handler, (message.body as? String) == "ready", frame == nil else { return }
        frame = message.frameInfo
    }
    private func tick() {
        guard let pid = processID, CreatorCodeProcess.identifier(view) == pid else { fail(.init(category: .runtime, runtimeReason: .pageFailed)); return }
        if let since = pendingSince, since.duration(to: .now) >= timeout { fail(.init(category: .runtime, runtimeReason: .timeout)); return }
        if let usage = CreatorCodeProcess.usage(pid) {
            if usage.ri_phys_footprint > memoryLimit { fail(.field("$", .resourceBudget, policy: true)); return }
            let cpu = usage.ri_user_time + usage.ri_system_time
            if let previous = previousUsage {
                let elapsed = previous.clock.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds)/1e18
                let ratio = Double(cpu >= previous.cpu ? cpu-previous.cpu : 0) / 1e9 / max(0.001, seconds)
                highCPU = ratio > 0.9 ? highCPU+1 : 0
                if highCPU >= 12 { fail(.field("$", .resourceBudget, policy: true)); return }
            }
            previousUsage = (.now, cpu)
        } else { fail(.init(category: .runtime, runtimeReason: .pageFailed)); return }
        // Do not wake a deliberately detached page with JavaScript. Outstanding calls
        // still have a deadline; process CPU/memory remain supervised while paused.
        if hostSuspended && ready && !checking { pendingSince = nil; return }
        guard let frame, !checking else { return }
        checking = true
        if pendingSince == nil { pendingSince = .now }
        let epoch = epoch
        view.evaluateJavaScript("({ready:document.readyState!=='loading',errors:window.__creatorCodeErrors||0,reason:window.__creatorCodeReason||'script'})", in: frame, in: .defaultClient) { [weak self] result in
            guard let self, !self.stopped, self.epoch == epoch else { return }
            guard case .success(let value) = result, let result = value as? [String: Any] else {
                self.fail(.init(category: .runtime, runtimeReason: .pageFailed)); return
            }
            if (result["errors"] as? Int ?? 1) > 0 {
                let reason = (result["reason"] as? String).flatMap(CreatorRepairIssue.RuntimeReason.init(rawValue:)) ?? .pageFailed
                self.fail(.init(category: .runtime, runtimeReason: reason)); return
            }
            self.checking = false
            self.samples += 1
            if result["ready"] as? Bool == true {
                let first = !self.ready; self.ready = true; self.pendingSince = nil
                if first { self.onReady?() }
            }
        }
    }
    func run(_ script: String, arguments: [String: Any] = [:]) {
        guard !stopped, let frame else { return }
        view.callAsyncJavaScript(script, arguments: arguments, in: frame, in: .page) { [weak self] result in
            if case .failure = result { self?.fail(.init(category: .runtime, runtimeReason: .pageFailed)) }
        }
    }
    func properties(_ json: String) {
        run("const p=JSON.parse(json);window.__wmParameters?.(p);window.wallpaperPropertyListener?.applyUserProperties?.(p);", arguments: ["json": json])
    }
    func setHostSuspended(_ value: Bool) {
        hostSuspended = value
        run("window.__creatorNativePaused(value);", arguments: ["value": value || playbackPaused])
    }
    func pause(_ value: Bool) {
        playbackPaused = value
        run("window.__creatorNativePaused(value);", arguments: ["value": value || hostSuspended])
    }
    func cursor(x: Double, y: Double, active: Bool) {
        guard x.isFinite, y.isFinite else { return }
        run("window.__creatorCursor(x,y,active);", arguments: ["x": min(1,max(0,x)), "y": min(1,max(0,y)), "active": active])
    }
    private func fail(_ issue: CreatorRepairIssue) {
        guard !stopped else { return }
        failure = issue; stop(); onFailure?(issue)
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; epoch = UUID(); monitor?.cancel(); monitor = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler, contentWorld: .defaultClient)
        if let processID { CreatorCodeProcess.terminate(view, owned: processID) }
        frame = nil; pendingSince = nil
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) { completionHandler(nil); download.cancel { _ in } }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) { decisionHandler(.cancel) }
    func cancel(_ download: WKDownload) { download.delegate = self; download.cancel { _ in } }
    private static let observer = """
    (()=>{if(window.top===window||location.href!=='about:srcdoc')return;let errors=0,reason='script';
      Object.defineProperty(window,'__creatorCodeErrors',{get:()=>errors});
      Object.defineProperty(window,'__creatorCodeReason',{get:()=>reason});
      const record=next=>{errors=Math.min(16,errors+1);if(reason==='script'||next!=='script')reason=next};
      // DOM attributes cross content worlds; arbitrary JS objects/Error values do not.
      // Sticky local state records only an enum, never source, paths or messages.
      const readFault=()=>{const value=document.documentElement?.getAttribute('data-creator-fault');if(['shader','resource','syntax','unhandled','script'].includes(value))record(value)};
      new MutationObserver(readFault).observe(document,{subtree:true,childList:true,attributes:true,attributeFilter:['data-creator-fault']});
      readFault();
      for(const kind of ['error','unhandledrejection','securitypolicyviolation'])addEventListener(kind,e=>{
        record(kind==='securitypolicyviolation'?'policy':kind==='unhandledrejection'?'unhandled':e.error?.name==='SyntaxError'||/SyntaxError/.test(e.message||'')?'syntax':'script');
      },true);
      window.webkit.messageHandlers.creatorCodeHealth.postMessage('ready');
    })();
    """
}
