import Foundation

extension CreatorWorkspace {
    struct LibraryMedia: Identifiable, Sendable { let id: String; let title: String }
    func libraryMedia() throws -> [LibraryMedia] {
        guard CreatorPersistence.exists(library) else { return [] }
        return try CreatorPersistence.directories(library).prefix(1000).compactMap { folder in
            guard (try? libraryMediaURL(folder.lastPathComponent)) != nil,
                  let bytes = try? CreatorPersistence.bytes(folder.appendingPathComponent("project.json"), limit: 256 * 1024),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
            return LibraryMedia(id: folder.lastPathComponent, title: String((object["title"] as? String ?? folder.lastPathComponent).prefix(120)))
        }
    }
    private func libraryMediaURL(_ id: String) throws -> URL {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"), !id.contains("\\") else { throw CreatorPersistence.Failure.invalidPath }
        let folder = library.appendingPathComponent(id)
        try CreatorPersistence.directory(folder)
        if CreatorRuntimeRegistry.isCandidate(folder) {
            let snapshot = try CreatorBundleManifest.read(folder)
            guard let media = snapshot.manifest?.media else { throw CreatorPersistence.Failure.invalidRecord }
            return folder.appendingPathComponent(media.base.path)
        }
        let bytes = try CreatorPersistence.bytes(folder.appendingPathComponent("project.json"), limit: 256 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let name = (object["image"] as? [String: Any])?["file"] as? String ?? object["file"] as? String,
              !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              CreatorMediaAnalysis.imageExtensions.union(CreatorMediaAnalysis.videoExtensions).contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { throw CreatorPersistence.Failure.invalidPath }
        return folder.appendingPathComponent(name)
    }
    func importLibraryMedia(_ id: String, projectID: UUID?) async throws -> UUID {
        try await importMedia(libraryMediaURL(id), projectID: projectID)
    }
    func attachMedia(_ media: CreatorPreparedMedia, projectID: UUID?) async throws -> UUID {
        try beginMediaWrite(); try media.validate(); try Task.checkCancellation()
        let isNew = projectID == nil
        let project: CreatorProject
        if let projectID { project = try await store.project(projectID) }
        else { project = try await store.createProject(title: "Media wallpaper") }
        do {
            var document: CreatorEngineDocument?
            if let revision = project.selectedRevisionID {
                let snapshot = try await store.snapshot(projectID: project.id, revisionID: revision)
                document = try snapshot.files["index.html"].flatMap { try CreatorEngineDocument.read(String(decoding: $0, as: UTF8.self)) }
            }
            if document?.engine.usesMedia != true {
                guard let master = try CreatorMasterCatalog.all().first(where: { $0.id == (media.binding.kind == .video ? "cinema" : "rain") }) else { throw CreatorPersistence.Failure.invalidRecord }
                document = try CreatorEngineDocument.read(master.source())
            }
            guard var document else { throw CreatorPersistence.Failure.invalidRecord }
            document.metadata.media = media.binding
            let source = Data(try document.html().utf8)
            let specification = try CreatorCodeOutput.specification(projectID: project.id, html: source)
            _ = try await rebuild(specification, base: project.selectedRevisionID, source: source, assets: media.files)
            return project.id
        } catch {
            if isNew { let store = store; _ = await Task.detached { try? await store.deleteDraft(project.id) }.value }
            throw error
        }
    }
    func importMedia(_ url: URL, projectID: UUID?) async throws -> UUID {
        let media = try await CreatorMediaAnalysis.prepare(url)
        return try await attachMedia(media, projectID: projectID)
    }
    func pasteImage(_ data: Data, projectID: UUID?) async throws -> UUID {
        try await attachMedia(CreatorMediaAnalysis.image(data), projectID: projectID)
    }
    func exportProject(_ project: UUID, revision: UUID, to url: URL) async throws {
        let checked = try await store.publication(projectID: project, revisionID: revision)
        let data = try CreatorProjectArchive.encode(checked.snapshot)
        try Task.checkCancellation()
        try CreatorPersistence.atomicWrite(data, to: url, limit: CreatorProjectArchive.maximumBytes)
    }
    func importProject(_ url: URL) async throws -> UUID {
        try beginMediaWrite()
        let bytes = try CreatorPersistence.bytes(url, limit: CreatorProjectArchive.maximumBytes)
        let original = try CreatorProjectArchive.snapshot(bytes)
        if let media = original.manifest?.media, media.kind == .video, let video = original.assets[media.base.path] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try CreatorPersistence.directory(directory, create: true)
            let file = directory.appendingPathComponent(URL(fileURLWithPath: media.base.path).lastPathComponent)
            try CreatorPersistence.atomicWrite(video, to: file, limit: CreatorMediaFile.maximumBytes)
            _ = try await CreatorMediaAnalysis.prepare(file)
        }
        let project = try await store.createProject(title: original.manifest?.presentation?.title ?? "Imported wallpaper")
        do {
            var specification = original.specification; specification.projectID = project.id
            _ = try await rebuild(specification, base: nil, source: specification.kind == .code ? original.files["index.html"] : nil, assets: original.assets)
            return project.id
        } catch {
            let store = store; _ = await Task.detached { try? await store.deleteDraft(project.id) }.value
            throw error
        }
    }
}
