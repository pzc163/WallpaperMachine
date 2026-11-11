import Foundation

extension CreatorRevisionStore {
    /// Import by copying verified bytes into a new revision; the S0/S1.0 source is never rewritten.
    func importLegacy(_ directory: URL, title: String, baseRevisionID: UUID? = nil) throws -> CreatorRevision {
        let snapshot = try CreatorDraftStore.read(directory)
        guard snapshot.bundleVersion == 1 else { throw CreatorPersistence.Failure.unsupportedVersion }
        let projectID = snapshot.specification.projectID
        if !CreatorPersistence.exists(projectURL(projectID)) { _ = try createProject(title: title, id: projectID) }
        let ticket = try beginJob(projectID: projectID, baseRevisionID: baseRevisionID)
        do {
            let revision = try stage(snapshot.specification, for: ticket, legacy: true)
            guard revision.bundleDigest == snapshot.digest else { throw CreatorTemplate.Failure.changedContent }
            return try commit(ticket)
        } catch {
            try? cancel(ticket)
            throw error
        }
    }
}
