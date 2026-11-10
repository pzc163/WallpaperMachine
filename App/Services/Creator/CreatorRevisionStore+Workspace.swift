import Foundation

extension CreatorRevisionStore {
    /// Display names are workspace preferences, outside immutable source metadata and its digest.
    /// Renaming never rewrites project identity or weakens old validation evidence.
    struct DisplayName: Codable { var schemaVersion = 1; let value: String }
    struct WorkspaceProject: Identifiable, Sendable {
        let project: CreatorProject
        let title: String
        var id: UUID { project.id }
        var poster: URL? = nil
        var posterBundleDigest: String? = nil
    }
    func containsProject(_ id: UUID) throws -> Bool { try locked { CreatorPersistence.exists(projectURL(id)) } }
    func workspaceProjects() throws -> [WorkspaceProject] {
        try locked {
            guard CreatorPersistence.exists(projectsURL) else { return [] }
            let entries = try CreatorPersistence.directories(projectsURL)
            guard entries.count <= 1100 else { throw CreatorPersistence.Failure.tooLarge }
            return try entries.filter { !$0.lastPathComponent.hasPrefix(".") }.map { url in
                guard let id = UUID(uuidString: url.lastPathComponent) else { throw CreatorPersistence.Failure.invalidPath }
                let project = try readProject(id)
                let nameURL = projectURL(id).appendingPathComponent("display-name.json")
                let name = CreatorPersistence.exists(nameURL) ? try CreatorPersistence.read(DisplayName.self, at: nameURL) : nil
                guard name == nil || name?.schemaVersion == 1,
                      name.map({ CreatorBundlePresentation.validText($0.value, limit: 60) }) ?? true
                else { throw CreatorPersistence.Failure.invalidRecord }
                var row = WorkspaceProject(project: project, title: name?.value ?? project.title)
                if let revisionID = project.selectedRevisionID,
                   let revision = try? CreatorPersistence.read(CreatorRevision.self, at: revisionURL(projectID: id, revisionID: revisionID).appendingPathComponent("revision.json")),
                   revision.posterDigest != nil {
                    row.poster = bundleURL(projectID: id, revisionID: revisionID)
                    row.posterBundleDigest = revision.bundleDigest
                }
                return row
            }.sorted { $0.project.createdAt == $1.project.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.project.createdAt > $1.project.createdAt }
        }
    }
    func setDisplayName(_ id: UUID, title: String) throws {
        try locked {
            _ = try readProject(id)
            guard CreatorBundlePresentation.validText(title, limit: 60) else { throw CreatorPersistence.Failure.invalidRecord }
            try Task.checkCancellation()
            try CreatorPersistence.write(DisplayName(value: title), to: projectURL(id).appendingPathComponent("display-name.json"))
        }
    }
    /// Only Creator's source directory is removed. Published bytes and registry bindings survive.
    func deleteDraft(_ id: UUID) throws {
        try locked {
            let project = try readProject(id)
            guard project.activeJobID == nil, try readConversation(id).turns.last?.state.terminal != false
            else { throw CreatorPersistence.Failure.busy }
            try Task.checkCancellation()
            let retired = projectsURL.appendingPathComponent(".deleted-" + CreatorPersistence.uuidName(id))
            guard !CreatorPersistence.exists(retired) else { throw CreatorPersistence.Failure.busy }
            try FileManager.default.moveItem(at: projectURL(id), to: retired)
            // The rename is the deletion commit; a crash cannot expose half a history.
            try FileManager.default.removeItem(at: retired)
        }
    }
}
