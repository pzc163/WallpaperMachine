import Foundation

/// Mutable project pointers; revisions referenced here remain immutable.
struct CreatorProject: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    var title: String
    let createdAt: Int64
    var revisionIDs: [UUID]
    var latestRevisionID: UUID?
    var lastValidatedRevisionID: UUID?
    var selectedRevisionID: UUID?
    var publishedWallpaperID: String?
    var activeJobID: UUID?

    var identityDigest: String {
        // Mutable history/selection pointers do not invalidate an older revision's report.
        CreatorPersistence.hash(Data("\(id.uuidString)|\(createdAt)|\(title.utf8.count):\(title)".utf8))
    }

    func validate() throws {
        guard schemaVersion == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.unicodeScalars.count <= 60, createdAt >= 0, revisionIDs.count <= 1000,
              Set(revisionIDs).count == revisionIDs.count,
              [latestRevisionID, lastValidatedRevisionID, selectedRevisionID].compactMap({ $0 }).allSatisfy(revisionIDs.contains),
              publishedWallpaperID == nil || publishedWallpaperID == "ai-" + CreatorPersistence.uuidName(id)
                || publishedWallpaperID == CreatorTemplate.idPrefix + CreatorPersistence.uuidName(id)
        else { throw CreatorPersistence.Failure.invalidRecord }
    }
}
