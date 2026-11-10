import AppKit
import Foundation

/// Creates a preview from the draft store without weakening installed-project path validation.
@MainActor
enum CreatorPreview {
    static func make(directory: URL, store: CreatorDraftStore, expectedDigest: String? = nil) async throws
        -> (snapshot: CreatorDraftStore.Snapshot, surface: WebWallpaperPreviewSurface) {
        let snapshot = try await store.snapshot(directory, expectedDigest: expectedDigest)
        try Task.checkCancellation()
        guard snapshot.bundleVersion == 1 else { throw CreatorPersistence.Failure.incompleteBundle }
        return try makeSurface(snapshot: snapshot, directory: directory)
    }

    static func make(projectID: UUID, revisionID: UUID, store: CreatorRevisionStore) async throws
        -> (snapshot: CreatorDraftStore.Snapshot, surface: WebWallpaperPreviewSurface) {
        let snapshot = try await store.snapshot(projectID: projectID, revisionID: revisionID)
        try Task.checkCancellation()
        let result = try makeSurface(snapshot: snapshot, directory: store.bundleURL(projectID: projectID, revisionID: revisionID))
        result.surface.page.creatorSnapshotLoader = { try await store.snapshot(projectID: projectID, revisionID: revisionID) }
        return result
    }

    private static func makeSurface(snapshot: CreatorDraftStore.Snapshot, directory: URL) throws
        -> (snapshot: CreatorDraftStore.Snapshot, surface: WebWallpaperPreviewSurface) {
        let specification = snapshot.specification
        let properties: [String: Any]
        let title: String
        if let templateID = specification.templateID, let parameters = specification.parameters {
            let definition = try CreatorTemplateCatalog.definition(templateID)
            properties = try definition.properties(for: parameters)
            title = definition.label
        } else {
            properties = ["hue": ["value": specification.hue], "speed": ["value": specification.speed]]
            title = "S0 · \(specification.kind.rawValue)"
        }
        let data = try JSONSerialization.data(withJSONObject: properties, options: .sortedKeys)
        let request = try WallpaperPreviewRequest(.init(
            wallpaperId: snapshot.wallpaperID, title: title, kind: .webpage,
            projectPath: directory.path, entryFile: "index.html", assetsPath: directory.path,
            propertiesJson: String(decoding: data, as: UTF8.self), fps: 30, scalingMode: .fill,
            scalingFactor: 1, volume: 0, engineOptions: nil, lutPath: nil, sceneQuality: .wallpaperEngineDefault))
        // No file/directory properties exist in this format, so this surface never imports user assets.
        let surface = WebWallpaperPreviewSurface(request: request, generation: 0, inspectable: false)
        surface.page.expectedCreatorDigest = snapshot.digest
        return (snapshot, surface)
    }
}
