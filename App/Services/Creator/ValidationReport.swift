import Foundation

/// Native validation evidence bound to bytes, immutable metadata and the current host contract.
struct ValidationReport: Codable, Equatable, Sendable {
    struct Context: Codable, Equatable, Sendable {
        let policyVersion: Int
        let sdkVersion: Int
        let hostVersion: String
        let testProfile: String
        let width: Int
        let height: Int

        static var current: Context {
            Context(policyVersion: 1, sdkVersion: 1, hostVersion: ClientPaths.buildStamp(),
                    testProfile: "template-structure-v1", width: 960, height: 540)
        }

        func validate() throws {
            guard policyVersion == 1, sdkVersion == 1, !hostVersion.isEmpty, hostVersion.utf8.count <= 128,
                  testProfile == "template-structure-v1", (1...4096).contains(width), (1...4096).contains(height)
            else { throw CreatorPersistence.Failure.unsupportedVersion }
        }
    }
    enum Result: String, Codable, Sendable { case passed, failed, notChecked }
    let schemaVersion: Int
    let id: UUID
    let projectID: UUID
    let revisionID: UUID
    let projectIdentityDigest: String
    let revisionDigest: String
    let renderDigest: String
    let posterDigest: String?
    let bundleDigest: String
    let templateRevision: Int
    let context: Context
    let results: [String: Result]
    let measuredMetrics: [String: Double]
    let validatedAt: Int64

    var allowsPreview: Bool {
        results == ["structure": .passed, "sourceReconstruction": .passed, "policy": .passed,
                    "runtime": .notChecked, "posterCapture": .notChecked]
    }
}
