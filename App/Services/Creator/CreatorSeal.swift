import Foundation

/// A sealed child records which immutable draft produced its native poster.
struct CreatorSeal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourceRevisionID: UUID
    let sourceRevisionDigest: String
    let renderDigest: String
    let context: ValidationReport.Context
    let metrics: [String: Double]

    func validate(snapshot: CreatorDraftStore.Snapshot) throws {
        try context.validate()
        guard schemaVersion == 1, context.testProfile == (snapshot.specification.kind == .code ? "code-runtime-v1" : "template-runtime-v1"),
              CreatorPersistence.validDigest(sourceRevisionDigest), renderDigest == (try snapshot.renderDigest),
              snapshot.bundleVersion == 2, snapshot.manifest?.packaging == .sealed,
              let jpeg = snapshot.files["preview.jpg"] else { throw CreatorPersistence.Failure.invalidRecord }
        try CreatorPosterMetadata.validate(jpeg: jpeg, metrics: metrics, context: context)
    }
}
