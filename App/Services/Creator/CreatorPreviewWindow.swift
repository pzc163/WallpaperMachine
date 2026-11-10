import AppKit
import Observation
import SwiftUI

/// An explicitly opened, disposable window. The normal test gate never shows this window.
@MainActor @Observable
final class CreatorPreviewWindow: NSObject, NSWindowDelegate {
    enum Aspect: String, CaseIterable { case wide = "16:9", desktop = "16:10", portrait = "9:16"
        var ratio: CGFloat { switch self { case .wide: 16.0 / 9; case .desktop: 1.6; case .portrait: 9.0 / 16 } }
    }
    var aspect = Aspect.wide
    var paused = false
    var failure = false
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var surface: WebWallpaperPreviewSurface?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    var contentView: NSView? { surface?.view }

    func open(project: UUID, revision: UUID, store: CreatorRevisionStore, controller: PanelController) async throws {
        close()
        let (_, surface) = try await CreatorPreview.make(projectID: project, revisionID: revision, store: store)
        self.surface = surface
        surface.onReady = { [weak self] in self?.timeout?.cancel(); self?.timeout = nil }
        surface.onFailure = { [weak self] _ in self?.fail() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Creator preview"); window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: CreatorPreviewContent(preview: self).environment(controller))
        window.minSize = NSSize(width: 360, height: 300)
        self.window = window
        do {
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)); self?.fail() } catch {}
            }
            try await surface.start(); try Task.checkCancellation()
            window.center(); window.makeKeyAndOrderFront(nil)
        } catch { close(); throw error }
    }
    func properties(_ values: [String: CreatorTemplateCatalog.Value]) throws {
        let object = values.mapValues { ["value": $0.json] }
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try surface?.applyProperties(String(decoding: data, as: UTF8.self))
    }
    func pause(_ value: Bool) throws { try surface?.setPaused(value); paused = value }
    func setAspect(_ value: Aspect) { aspect = value }
    private func fail() { failure = true; timeout?.cancel(); timeout = nil; surface?.stop() }
    func windowWillClose(_ notification: Notification) { stop() }
    func close() { window?.close(); stop(); window = nil }
    private func stop() { timeout?.cancel(); timeout = nil; surface?.stop(); surface = nil }
}

