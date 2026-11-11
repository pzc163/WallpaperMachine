import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor enum CreatorCodeTestFixture {
    static func preview(root: URL, source: String = CreatorCodeWorkflowTests.html) async throws -> WebWallpaperPreviewSurface {
        let store = CreatorRevisionStore(root: root.appendingPathComponent(UUID().uuidString))
        let project = try await store.createProject(title: "Code probe")
        let job = try await store.beginJob(projectID: project.id)
        let html = Data(source.utf8)
        _ = try await store.stage(CreatorCodeOutput.specification(projectID: project.id, html: html), for: job, source: html)
        let draft = try await store.commit(job, validatingStructure: true)
        let preview = try await CreatorPreview.make(projectID: project.id, revisionID: draft.id, store: store)
        let surface = preview.surface
        surface.view.setFrameSize(NSSize(width: 320, height: 180)); surface.view.layoutSubtreeIfNeeded()
        try await surface.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !surface.page.isLoaded && surface.page.creatorCodeFailure == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard surface.page.isLoaded else { surface.stop(); throw surface.page.creatorCodeFailure ?? .init(category: .runtime, runtimeReason: .timeout) }
        return surface
    }
    static func js(_ surface: WebWallpaperPreviewSurface, _ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        let frame = try XCTUnwrap(surface.page.creatorCode?.frame)
        return try await surface.page.webView.callAsyncJavaScript(script, arguments: arguments, in: frame, contentWorld: .page)
    }
}
