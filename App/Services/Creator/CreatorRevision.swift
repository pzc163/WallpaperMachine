import Foundation

/// Immutable provenance and content binding for one revision, outside its executable bundle.
struct CreatorRevision: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let projectID: UUID
    let parentID: UUID?
    let promptSummary: String
    let providerID: String?
    let modelID: String?
    let outputSchemaVersion: Int?
    let bundleVersion: Int
    let sdkVersion: Int
    let policyVersion: Int
    let templateID: String
    let templateRevision: Int
    let normalizedParameters: [String: CreatorTemplateCatalog.Value]
    let renderDigest: String
    let posterDigest: String?
    let bundleDigest: String
    let createdAt: Int64

    func validate(against snapshot: CreatorDraftStore.Snapshot) throws {
        let identity = CreatorBundleManifest.templateIdentity(snapshot.specification)
        let actualRenderDigest = try snapshot.renderDigest
        guard schemaVersion == 1, projectID == snapshot.specification.projectID, parentID != id,
              promptSummary.unicodeScalars.count <= 240, providerID == nil, modelID == nil, outputSchemaVersion == nil,
              bundleVersion == snapshot.bundleVersion, sdkVersion == 1, policyVersion == 1,
              templateID == identity.id, templateRevision == identity.revision,
              normalizedParameters == CreatorBundleManifest.parameters(snapshot.specification),
              renderDigest == actualRenderDigest, posterDigest == snapshot.manifest?.posterDigest,
              bundleDigest == snapshot.digest, createdAt >= 0 else { throw CreatorPersistence.Failure.invalidRecord }
    }
}
