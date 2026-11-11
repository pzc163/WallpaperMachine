import Network
import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorPreviewTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-web-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func make(_ kind: CreatorTemplate.Kind = .stars) async throws -> (URL, CreatorDraftStore.Snapshot, WebWallpaperPreviewSurface) {
        let store = CreatorDraftStore(root: root)
        let directory = try await store.create(.init(projectID: UUID(), kind: kind))
        let result = try await CreatorPreview.make(directory: directory, store: store)
        return (directory, result.snapshot, result.surface)
    }

    private static func loaded(_ page: WebWallpaperPage) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard page.isLoaded else { throw CreatorTemplate.Failure.invalidBundle }
    }

    private func js(_ page: WebWallpaperPage, _ code: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(code, arguments: arguments, in: nil, contentWorld: .page)
    }

    func testThreeDraftTemplatesPaintAndDeliverPropertiesWithoutInstallingOrOpeningWindows() async throws {
        for kind in CreatorTemplate.Kind.templates {
            let (_, _, surface) = try await make(kind)
            defer { surface.stop() }
            try await surface.start()
            try await Self.loaded(surface.page)
            XCTAssertNil(surface.page.webView.window)
            XCTAssertFalse(surface.page.webView.configuration.websiteDataStore.isPersistent)
            XCTAssertEqual(surface.page.webView.url, CreatorWebResources.entryURL)
            let painted = try await js(surface.page, "const c=document.querySelector('canvas'); return c.getContext('2d').getImageData(0,0,1,1).data[3]===255;") as? Bool
            XCTAssertEqual(painted, true)
            let before = try await js(surface.page, "return document.querySelector('canvas').toDataURL();") as? String
            try surface.setPaused(true)
            try surface.applyProperties(#"{"hue":{"value":40},"speed":{"value":0}}"#)
            try await Task.sleep(for: .milliseconds(100))
            let after = try await js(surface.page, "return document.querySelector('canvas').toDataURL();") as? String
            XCTAssertNotEqual(before, after, "Native properties must reach the actual template")
            surface.view.setFrameSize(NSSize(width: 400, height: 700))
            _ = try await js(surface.page, "window.dispatchEvent(new Event('resize')); return true;")
            try surface.setPaused(false)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    }

    private func withNetworkProbe(_ probe: (WebWallpaperPage, String) async throws -> Void) async throws {
        let server = try CreatorLoopbackProbe()
        defer { server.stop() }
        let port = try await server.readyPort()
        // Positive control proves that this listener observes attempted connections.
        let control = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        control.start(queue: DispatchQueue(label: "creator-positive-control"))
        let deadline = Date().addingTimeInterval(3)
        while server.connections == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        control.cancel()
        XCTAssertEqual(server.connections, 1)

        let (_, _, surface) = try await make()
        defer { surface.stop() }
        try await surface.start()
        try await Self.loaded(surface.page)
        try await probe(surface.page, "http://127.0.0.1:\(port)")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.connections, 1, "Blocked requests must not merely fail after being sent")
        XCTAssertEqual(surface.page.webView.url, CreatorWebResources.entryURL)
    }

    func testNetworkAPIsAndRemoteResourcesAreBlockedBeforeReachingLocalServer() async throws {
        try await withNetworkProbe { page, url in
          let result = try await js(page, """
          const timeout = p => Promise.race([p, new Promise(r=>setTimeout(()=>r(false),1500))]);
          const fetchBlocked = await fetch(url).then(()=>false,()=>true);
          const xhrBlocked = await timeout(new Promise(r=>{const x=new XMLHttpRequest();x.onload=()=>r(false);x.onerror=()=>r(true);x.open('GET',url);x.send();}));
          const socketBlocked = await timeout(new Promise(r=>{try{const s=new WebSocket(url.replace('http:','ws:'));s.onopen=()=>{s.close();r(false)};s.onerror=()=>r(true)}catch(e){r(true)}}));
          const imageBlocked = await timeout(new Promise(r=>{const i=new Image();i.onload=()=>r(false);i.onerror=()=>r(true);i.src=url+'/image';document.body.append(i)}));
          const styleBlocked = await timeout(new Promise(r=>{const l=document.createElement('link');l.rel='stylesheet';l.onload=()=>r(false);l.onerror=()=>r(true);l.href=url+'/style';document.head.append(l)}));
          const scriptBlocked = await timeout(new Promise(r=>{const s=document.createElement('script');s.onload=()=>r(false);s.onerror=()=>r(true);s.src=url+'/script';document.head.append(s)}));
          const beaconBlocked = await timeout(new Promise(r=>{
            const violation=e=>{if(e.effectiveDirective==='connect-src' && e.blockedURI.startsWith(url)){removeEventListener('securitypolicyviolation',violation);r(true)}};
            addEventListener('securitypolicyviolation',violation);
            try{if(!navigator.sendBeacon(url+'/beacon','x')){removeEventListener('securitypolicyviolation',violation);r(true)}}catch(e){removeEventListener('securitypolicyviolation',violation);r(true)}
          }));
          const workerBlocked = await timeout(new Promise(r=>{try{const w=new Worker(url+'/worker');w.onerror=()=>{w.terminate();r(true)};w.onmessage=()=>{w.terminate();r(false)}}catch(e){r(true)}}));
          return [fetchBlocked,xhrBlocked,socketBlocked,imageBlocked,styleBlocked,scriptBlocked,beaconBlocked,workerBlocked];
          """, arguments: ["url": url]) as? [Bool]
          XCTAssertEqual(result, Array(repeating: true, count: 8))
        }
    }

    func testEventSourceIsBlockedBeforeConnecting() async throws {
        try await codeNetworkProbe("const e=new EventSource(url+'/events');setTimeout(()=>e.close(),500);")
    }

    func testFontIsBlockedBeforeConnecting() async throws {
        try await withNetworkProbe { page, url in
            let blocked = try await js(page, "return await new FontFace('probe',`url(${url}/font)`).load().then(()=>false,()=>true);", arguments: ["url": url]) as? Bool
            XCTAssertEqual(blocked, true)
        }
    }

    func testMediaIsBlockedBeforeConnecting() async throws {
        try await codeNetworkProbe("const v=document.createElement('video');document.body.append(v);v.src=url+'/video';v.load();")
    }

    func testFormsAreBlockedBeforeNavigating() async throws {
        try await withNetworkProbe { page, url in
            let blocked = try await js(page, """
              return await new Promise(r=>{
                const violation=e=>{if(e.effectiveDirective==='form-action'){removeEventListener('securitypolicyviolation',violation);r(true)}};
                addEventListener('securitypolicyviolation',violation);
                const f=document.createElement('form');f.action=url+'/form';f.method='post';document.body.append(f);f.submit();setTimeout(()=>r(false),1500);
              });
              """, arguments: ["url": url]) as? Bool
            XCTAssertEqual(blocked, true)
        }
    }

    func testDownloadLinksAreBlockedBeforeConnecting() async throws {
        try await codeNetworkProbe("const a=document.createElement('a');a.href=url+'/download';a.download='probe';document.body.append(a);a.click();")
    }

    /// The original S0 cases now exercise generatedOfflineV1's actual installed-page executor.
    /// Policy teardown is an explicit native refusal; no page-owned error/timeout is trusted.
    private func codeNetworkProbe(_ script: String) async throws {
        let server = try CreatorLoopbackProbe(); defer { server.stop() }
        let port = try await server.readyPort()
        let control = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        control.start(queue: DispatchQueue(label: "s4-positive-control"))
        let deadline = ContinuousClock.now + .seconds(3)
        while server.connections == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.connections, 1); control.cancel()
        let surface = try await CreatorCodeTestFixture.preview(root: root)
        defer { surface.stop() }
        do { _ = try await CreatorCodeTestFixture.js(surface, script + "return true;", arguments: ["url": "http://127.0.0.1:\(port)"]) }
        catch {
            let deadline = ContinuousClock.now + .seconds(3)
            while surface.page.creatorCodeFailure == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(surface.page.creatorCodeFailure)
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(server.connections, 1, "No connection beyond the positive control")
    }

    func testRedirectEndpointsAreNeverContacted() async throws {
        try await withNetworkProbe { page, url in
            _ = try await js(page, "location.href=url+'/redirect';return true;", arguments: ["url": url])
        }
    }

    func testNoFileGrantOrNativeCapabilities() async throws {
        let (_, _, surface) = try await make()
        defer { surface.stop() }
        try await surface.start()
        try await Self.loaded(surface.page)
        let secret = root.appendingPathComponent("outside.txt")
        try Data("must-not-leave-native".utf8).write(to: secret)
        let rejected = try await js(surface.page, """
          const readBlocked = await fetch(file).then(()=>false,()=>true);
          const outsideBundleBlocked = await fetch('wm-creator://bundle/../outside.txt').then(()=>false,()=>true);
          const encodedPathBlocked = await fetch('wm-creator://bundle/%2e%2e/%2e%2e/outside.txt').then(()=>false,()=>true);
          return [readBlocked,outsideBundleBlocked,encodedPathBlocked];
          """, arguments: ["file": secret.absoluteString]) as? [Bool]
        XCTAssertEqual(rejected, [true, true, true])
        var nativeRequests = 0
        surface.page.onRandomFileRequest = { _, _ in nativeRequests += 1 }
        _ = try await js(surface.page, "window.webkit.messageHandlers.mweWallpaper.postMessage({type:'randomFileRequest',requestId:'1',propertyId:'x'}); return true;")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(nativeRequests, 0)
        var captureRequested = false
        surface.page.onAudioDemandChanged = { captureRequested = captureRequested || $0 }
        surface.page.setAudioResponseEnabled(true)
        _ = try await js(surface.page, "wallpaperRegisterAudioListener(()=>{});return true;")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(captureRequested, "Creator pages must never request a capture tap")
    }

    func testFramesCannotExecute() async throws {
        let (_, _, surface) = try await make()
        defer { surface.stop() }
        try await surface.start()
        try await Self.loaded(surface.page)
        let blocked = try await js(surface.page, """
          const frame=document.createElement('iframe');frame.srcdoc='<script>parent.__frameRan=true;<\\/script>';document.body.append(frame);
          await new Promise(r=>setTimeout(r,100)); return window.__frameRan!==true;
          """) as? Bool
        XCTAssertEqual(blocked, true)
    }

    func testPopupsAreDenied() async throws {
        let (_, _, surface) = try await make()
        defer { surface.stop() }
        try await surface.start()
        try await Self.loaded(surface.page)
        let blocked = try await js(surface.page, "return window.open('https://example.invalid/') === null;") as? Bool
        XCTAssertEqual(blocked, true)
    }

    func testCaptureIsUnavailableOrDeniedWithoutOpeningDevices() async throws {
        let (_, _, surface) = try await make()
        defer { surface.stop() }
        try await surface.start()
        try await Self.loaded(surface.page)
        let blocked = try await js(surface.page, """
          if (!navigator.mediaDevices) return true;
          return await navigator.mediaDevices.getUserMedia({audio:true}).then(()=>false,()=>true);
          """) as? Bool
        XCTAssertEqual(blocked, true)
    }

    func testChangedSourceCannotReplaceLoadedSnapshotAndReloadFailsClosed() async throws {
        let (directory, _, surface) = try await make()
        defer { surface.stop() }
        try await surface.start()
        try await Self.loaded(surface.page)
        try Data("<script>window.__tampered=true</script>".utf8).write(to: directory.appendingPathComponent("index.html"))
        let unchanged = try await js(surface.page, "return !!document.querySelector('canvas') && !window.__tampered;") as? Bool
        XCTAssertEqual(unchanged, true)
        let failed = expectation(description: "Reload rejects changed bytes")
        surface.page.onFailure = { _ in failed.fulfill() }
        surface.page.load()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(surface.page.isLoaded)
    }

    func testStopFencesPendingLoadsAndInfiniteCodeIsRejectedBeforeExecution() async throws {
        let (directory, _, surface) = try await make()
        var ready = false
        surface.onReady = { ready = true }
        try await surface.start()
        surface.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(ready)
        XCTAssertFalse(surface.page.isLoaded)
        try Data("<script>while(true){}</script>".utf8).write(to: directory.appendingPathComponent("index.html"))
        do {
            _ = try await CreatorPreview.make(directory: directory, store: CreatorDraftStore(root: root))
            XCTFail("Executed untrusted source instead of refusing it")
        } catch {}
    }

    func testRealPreviewImportAndInstalledHostUseTheSameRestrictedProtocol() async throws {
        let (directory, snapshot, preview) = try await make(.clock)
        defer { preview.stop() }
        try await preview.start()
        try await Self.loaded(preview.page)
        let library = root.appendingPathComponent("library")
        let publisher = CreatorPublisher(root: root.appendingPathComponent("publication"), library: library)
        let destination = try await publisher.publish(directory, expectedDigest: snapshot.digest) { installed in
            try await Self.verifyInstalled(installed)
        }
        XCTAssertEqual(try CreatorDraftStore.read(destination).digest, snapshot.digest)
    }

    private static func verifyInstalled(_ directory: URL) async throws {
        // The same page class as desktop playback; no desktop window is constructed.
        let page = WebWallpaperPage(projectURL: directory, entryFile: "index.html")
        defer { page.stop() }
        page.webView.setFrameSize(NSSize(width: 320, height: 200))
        page.load()
        try await loaded(page)
        XCTAssertEqual(page.webView.url, CreatorWebResources.entryURL)
        XCTAssertFalse(page.webView.configuration.websiteDataStore.isPersistent)
        let present = try await page.webView.callAsyncJavaScript("return document.querySelector('#clock').textContent.length > 0;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(present, true)
        XCTAssertNil(page.webView.window)
    }
}

final class CreatorLoopbackProbe: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var accepted: [NWConnection] = []
    private let queue = DispatchQueue(label: "creator-loopback-probe")
    private var port: UInt16?
    var connections: Int { lock.lock(); defer { lock.unlock() }; return accepted.count }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // Do not reset a newly accepted socket: the positive control could retry,
            // and cancelling an unstarted Network connection also distorts the probe.
            connection.start(queue: self.queue)
            self.lock.lock(); self.accepted.append(connection); self.lock.unlock()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock(); self.port = self.listener.port?.rawValue; self.lock.unlock()
        }
        listener.start(queue: queue)
    }
    func readyPort() async throws -> UInt16 {
        for _ in 0..<300 {
            if let value = readPort() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
    private func readPort() -> UInt16? { lock.lock(); defer { lock.unlock() }; return port }
    func stop() {
        listener.cancel()
        lock.lock(); let connections = accepted; accepted = []; lock.unlock()
        for connection in connections { connection.cancel() }
    }
}
