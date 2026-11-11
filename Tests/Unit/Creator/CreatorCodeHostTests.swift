import AppKit
import Network
import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorCodeHostTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-code-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    func testOpaqueFrameHasNoParentStorageFilesNativeBridgeOrPopupCapability() async throws {
        let surface = try await CreatorCodeTestFixture.preview(root: root); defer { surface.stop() }
        let result = try await CreatorCodeTestFixture.js(surface, """
            const denied=fn=>{try{fn();return false}catch{return true}};
            return {parent:denied(()=>parent.document.body),storage:denied(()=>localStorage.setItem('secret','x')),
              native:!window.webkit?.messageHandlers?.creatorCodeHealth,
              popup:window.open('about:blank')===null,worker:typeof Worker==='undefined'||denied(()=>new Worker('data:text/javascript,0'))};
            """) as? [String: Bool]
        for key in ["parent", "storage", "native", "popup"] { XCTAssertEqual(result?[key], true, key) }
        XCTAssertFalse(surface.page.webView.configuration.websiteDataStore.isPersistent)
    }
    func testCodeNetworkAndNavigationMatrixNeverContactsListener() async throws {
        let server = try CreatorLoopbackProbe(); defer { server.stop() }
        let port = try await server.readyPort()
        let control = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        control.start(queue: DispatchQueue(label: "code-host-positive")); try await wait { server.connections == 1 }; control.cancel()
        let groups = [
            "fetch(url).catch(()=>{});const x=new XMLHttpRequest();x.open('GET',url);x.send();try{new WebSocket(url.replace('http','ws'))}catch{};try{navigator.sendBeacon(url,'x')}catch{};",
            "for(const tag of ['img','script','iframe']){const e=document.createElement(tag);e.src=url;document.body.append(e)};const style=document.createElement('style');style.textContent='@font-face{font-family:probe;src:url('+url+')}body{font-family:probe;background-image:url('+url+')}';document.head.append(style);",
            "const a=document.createElement('a');a.href=url+'/attachment-redirect';a.download='x';a.click();try{top.location.href=url}catch{};location.href=url;",
            "const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['x'],{type:'application/octet-stream'}));a.download='x';a.click();a.href='data:text/plain,x';a.click();",
            "fetch('file:///tmp/creator-forbidden-file').catch(()=>{});fetch('wm-creator://bundle/project.json').catch(()=>{});"
        ]
        for group in groups {
            let surface = try await CreatorCodeTestFixture.preview(root: root); defer { surface.stop() }
            do { _ = try await CreatorCodeTestFixture.js(surface, "const url='http://127.0.0.1:\(port)';" + group + "return true;") }
            catch { try await wait { surface.page.creatorCodeFailure != nil } }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(server.connections, 1)
            XCTAssertTrue(surface.page.webView.url == CreatorWebResources.entryURL || surface.page.creatorCodeFailure != nil, "a terminated process may clear the parent URL")
        }
    }
    func testCursorCoordinatesPauseResumeResizeAndProcessExitUseNativeHost() async throws {
        let surface = try await CreatorCodeTestFixture.preview(root: root); defer { surface.stop() }
        let page = surface.page
        _ = try await CreatorCodeTestFixture.js(surface, "window.moves=0;addEventListener('mousemove',()=>moves++);return true;")
        page.applyGeneralProperties(fps: 144); page.applyDisplayRefreshRate(144)
        XCTAssertEqual(page.pointerMoveInterval, 1.0 / 30, accuracy: 0.000001)
        page.applyGeneralProperties(fps: 12)
        XCTAssertEqual(page.pointerMoveInterval, 1.0 / 12, accuracy: 0.000001)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 80, y: 90), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        page.deliverMouse(event)
        try await Task.sleep(for: .milliseconds(60))
        let state = try await CreatorCodeTestFixture.js(surface, "return {x:wallpaperCursor.normalizedX,y:wallpaperCursor.normalizedY,active:wallpaperCursor.active,moves};") as? [String: Any]
        XCTAssertEqual(state?["x"] as? Double ?? -1, 0.25, accuracy: 0.01)
        XCTAssertEqual(state?["y"] as? Double ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(state?["active"] as? Bool, true); XCTAssertEqual(state?["moves"] as? Int, 1)
        page.setPaused(true); XCTAssertFalse(page.acceptsPointer)
        page.deliverMouse(event)
        page.setPresentationSuspended(true)
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertNil(page.creatorCodeFailure); XCTAssertFalse(page.creatorCode?.stopped ?? true)
        page.setPaused(false); XCTAssertFalse(page.acceptsPointer, "presentation suspension composes with user pause")
        page.setPresentationSuspended(false); XCTAssertTrue(page.acceptsPointer)
        surface.view.setFrameSize(NSSize(width: 180, height: 320)); surface.view.layoutSubtreeIfNeeded()
        page.deliverMouse(event); try await Task.sleep(for: .milliseconds(60))
        let moves = try await CreatorCodeTestFixture.js(surface, "return moves;") as? Int
        XCTAssertEqual(moves, 2)
        let code = try XCTUnwrap(page.creatorCode), pid = try XCTUnwrap(code.processID)
        XCTAssertTrue(CreatorCodeProcess.terminate(page.webView, owned: pid))
        try await wait { page.creatorCodeFailure != nil }
        XCTAssertFalse(page.isLoaded); XCTAssertFalse(page.acceptsPointer)
        XCTAssertEqual(page.creatorCodeFailure?.runtimeReason, .pageFailed)
    }
    func testShaderAndUnhandledErrorsProduceOnlySanitizedNativeCategories() async throws {
        for (script, expected) in [("Promise.reject(new Error('private_path_and_secret'));", CreatorRepairIssue.RuntimeReason.unhandled),
                                  ("setTimeout(()=>{throw new Error('private_path_and_secret')},0);", .script)] {
            let surface = try await CreatorCodeTestFixture.preview(root: root); defer { surface.stop() }
            _ = try? await CreatorCodeTestFixture.js(surface, script)
            try await wait { surface.page.creatorCodeFailure != nil }
            XCTAssertEqual(surface.page.creatorCodeFailure?.runtimeReason, expected)
            XCTAssertFalse(String(describing: surface.page.creatorCodeFailure).contains("private_path"))
        }
        // The actual shader error path is tested in its own fresh canvas, without a 2D context.
        let source = "<!doctype html><html><body><canvas></canvas><script>const c=document.querySelector('canvas');window.g=c.getContext('webgl');</script></body></html>"
        let surface = try await CreatorCodeTestFixture.preview(root: root, source: source); defer { surface.stop() }
        let supported = try await CreatorCodeTestFixture.js(surface, "return !!g;") as? Bool
        guard supported == true else { throw XCTSkip("WebGL is unavailable; software fallback is covered separately") }
        _ = try? await CreatorCodeTestFixture.js(surface, "const s=g.createShader(g.FRAGMENT_SHADER);g.shaderSource(s,'invalid GLSL');g.compileShader(s);return true;")
        try await wait { surface.page.creatorCodeFailure != nil }
        XCTAssertEqual(surface.page.creatorCodeFailure?.runtimeReason, .shader)
    }
}
