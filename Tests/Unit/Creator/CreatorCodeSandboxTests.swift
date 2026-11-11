import Network
import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorCodeSandboxTests: XCTestCase {
    final class Delegate: NSObject, WKNavigationDelegate {
        var loaded = false
        let sandbox: CreatorCodeSandbox
        init(_ sandbox: CreatorCodeSandbox) { self.sandbox = sandbox }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(!action.shouldPerformDownload && ["about:blank", "about:srcdoc"].contains(action.request.url?.absoluteString ?? "") ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { sandbox.cancel(download) }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { sandbox.cancel(download) }
    }
    func make(_ source: String, timeout: Duration = .seconds(2), memoryLimit: UInt64 = 512 * 1024 * 1024) async throws -> (CreatorCodeSandbox, Delegate) {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
        let sandbox = CreatorCodeSandbox(view: view, timeout: timeout, memoryLimit: memoryLimit), delegate = Delegate(sandbox)
        view.navigationDelegate = delegate
        view.loadHTMLString(CreatorCodeSandbox.container, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while !delegate.loaded && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(delegate.loaded)
        try sandbox.start(source: source)
        return (sandbox, delegate)
    }
    func wait(_ condition: @escaping @MainActor () -> Bool, seconds: Double = 5) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let success = condition()
        XCTAssertTrue(success)
    }
    func evaluate(_ sandbox: CreatorCodeSandbox, _ code: String) async throws -> Any? {
        let frame = try XCTUnwrap(sandbox.frame)
        return try await sandbox.view.callAsyncJavaScript(code, arguments: [:], in: frame, contentWorld: .page)
    }
    func testSandboxBlocksDownloadsEventSourceAndMediaBeforeAnyConnectionWithPositiveControl() async throws {
        let server = try CreatorLoopbackProbe(); defer { server.stop() }
        let port = try await server.readyPort()
        let control = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        control.start(queue: DispatchQueue(label: "s4-positive-control")); try await wait { server.connections == 1 }; control.cancel()
        for action in [
            "const a=document.createElement('a');a.href=url+'/download';a.download='x';document.body.append(a);a.click();",
            "const s=new EventSource(url+'/events');setTimeout(()=>s.close(),500);",
            "const v=document.createElement('video');document.body.append(v);v.src=url+'/media';v.load();"
        ] {
            let pair = try await make("<style>body{background:linear-gradient(45deg,#123,#456)}</style>")
            defer { pair.0.stop(); withExtendedLifetime(pair.1) {} }
            try await wait { pair.0.ready }
            do { _ = try await evaluate(pair.0, "const url='http://127.0.0.1:\(port)';" + action + "return true;") }
            catch {
                // A native policy violation may tear down the page before its JS reply arrives.
                try await wait { pair.0.failure != nil }
                XCTAssertEqual(pair.0.failure?.category, .runtime)
            }
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(server.connections, 1)
        }
    }
    func testInfiniteLoopTerminatesOwnedProcessWhileAnotherPageRemainsResponsive() async throws {
        let healthy = try await make("<div>healthy</div>")
        defer { healthy.0.stop(); withExtendedLifetime(healthy.1) {} }
        try await wait { healthy.0.ready }
        let bad = try await make("<script>while(true){}</script>", timeout: .milliseconds(700))
        defer { bad.0.stop(); withExtendedLifetime(bad.1) {} }
        let pid = try XCTUnwrap(bad.0.processID)
        XCTAssertNotEqual(pid, healthy.0.processID)
        try await wait { bad.0.stopped }
        XCTAssertEqual(bad.0.failure?.runtimeReason, .timeout)
        try await wait { CreatorCodeProcess.usage(pid) == nil }
        let alive = try await evaluate(healthy.0, "return 42;") as? Int
        XCTAssertEqual(alive, 42)
    }
    func testMicrotaskStarvationUsesExternalDeadlineAndStopsOnlyItsOwnProcess() async throws {
        let pair = try await make("<script>function spin(){queueMicrotask(spin)}spin()</script>", timeout: .milliseconds(700))
        defer { pair.0.stop(); withExtendedLifetime(pair.1) {} }
        let pid = try XCTUnwrap(pair.0.processID), start = ContinuousClock.now
        try await wait { pair.0.stopped }
        XCTAssertEqual(pair.0.failure?.runtimeReason, .timeout)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        try await wait { CreatorCodeProcess.usage(pid) == nil }
    }
    func testBoundedAllocationTripsNativeMemoryLimitAndReleasesProcess() async throws {
        let pair = try await make("<script>const buffers=[];function allocate(){if(buffers.length<20){const b=new Uint8Array(16*1024*1024);b.fill(17);buffers.push(b);setTimeout(allocate,40)}}setTimeout(allocate,50)</script>", memoryLimit: 192 * 1024 * 1024)
        defer { pair.0.stop(); withExtendedLifetime(pair.1) {} }
        let pid = try XCTUnwrap(pair.0.processID)
        try await wait { pair.0.stopped }
        XCTAssertEqual(pair.0.failure?.fields.first?.rule, .resourceBudget)
        try await wait { CreatorCodeProcess.usage(pid) == nil }
    }
    func testLogFloodAndCanvasAttributeOverBudgetAreRejectedWithoutKeepingPayloads() async throws {
        for code in ["for(let i=0;i<300;i++)console.log('private_payload')",
                     "const c=document.createElement('canvas');document.body.append(c);c.setAttribute('width','4096');c.setAttribute('height','4096')"] {
            let pair = try await make("<body><script>"+code+"</script></body>")
            defer { pair.0.stop(); withExtendedLifetime(pair.1) {} }
            try await wait { pair.0.stopped }
            XCTAssertEqual(pair.0.failure?.runtimeReason, .resource)
            XCTAssertFalse(String(describing: pair.0.failure).contains("private_payload"))
        }
    }
    func testSharedDataStoreFailsClosedAndLateCallbacksCannotReviveStoppedSandbox() async throws {
        let pair = try await make("<div>healthy</div>")
        defer { pair.0.stop(); withExtendedLifetime(pair.1) {} }
        try await wait { pair.0.ready }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = pair.0.view.configuration.websiteDataStore
        let shared = WKWebView(frame: .zero, configuration: configuration)
        CreatorCodeProcess.observe(shared)
        XCTAssertThrowsError(try CreatorCodeProcess.claim(pair.0.view))
        let samples = pair.0.samples, pid = try XCTUnwrap(pair.0.processID)
        pair.0.stop(); pair.0.stop()
        pair.0.cursor(x: 0.5, y: 0.5, active: true); pair.0.pause(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(pair.0.stopped); XCTAssertNil(pair.0.frame); XCTAssertEqual(pair.0.samples, samples)
        try await wait { CreatorCodeProcess.usage(pid) == nil }
        withExtendedLifetime(shared) {}
    }

}
