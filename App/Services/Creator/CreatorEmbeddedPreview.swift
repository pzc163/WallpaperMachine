import AppKit
import Observation

/// A disposable, muted, publication-validated surface; owns no window and never reaches the desktop.
@MainActor @Observable
final class CreatorEmbeddedPreview {
    enum State { case idle, loading, ready, failed }
    private(set) var state = State.idle
    private(set) var view: NSView?
    private(set) var revisionID: UUID?
    private(set) var paused = false
    @ObservationIgnored private var surface: WebWallpaperPreviewSurface?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func open(project: UUID, revision: UUID, store: CreatorRevisionStore) async throws {
        close()
        let token = generation
        state = .loading; revisionID = revision
        do {
            let (_, surface) = try await CreatorPreview.makePublished(projectID: project, revisionID: revision, store: store)
            guard generation == token else { surface.stop(); throw CancellationError() }
            self.surface = surface; view = surface.view
            surface.onReady = { [weak self] in
                guard let self, self.generation == token else { return }
                self.state = .ready; self.timeout?.cancel(); self.timeout = nil
            }
            surface.onFailure = { [weak self] _ in
                guard self?.generation == token else { return }; self?.fail()
            }
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)); if self?.generation == token { self?.fail() } } catch {}
            }
            try await surface.start(); try Task.checkCancellation()
            guard generation == token else { surface.stop(); throw CancellationError() }
        } catch {
            if generation == token { if error is CancellationError { close() } else { fail() } }
            throw error
        }
    }
    func properties(_ values: [String: CreatorTemplateCatalog.Value]) throws {
        let data = try JSONSerialization.data(withJSONObject: values.mapValues { ["value": $0.json] }, options: .sortedKeys)
        try surface?.applyProperties(String(decoding: data, as: UTF8.self))
    }
    func pause(_ value: Bool) throws { try surface?.setPaused(value); paused = value }
    func close() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        surface?.stop(); surface = nil; view = nil; revisionID = nil; state = .idle; paused = false
    }
    private func fail() { close(); state = .failed }
}
