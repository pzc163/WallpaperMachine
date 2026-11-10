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

        var runtime: Context {
            Context(policyVersion: policyVersion, sdkVersion: sdkVersion, hostVersion: hostVersion,
                    testProfile: "template-runtime-v1", width: width, height: height)
        }

        func sameHost(as other: Context) -> Bool {
            policyVersion == other.policyVersion && sdkVersion == other.sdkVersion && hostVersion == other.hostVersion
        }

        func validate() throws {
            guard policyVersion == 1, sdkVersion == 1, !hostVersion.isEmpty, hostVersion.utf8.count <= 128,
                  ["template-structure-v1", "template-runtime-v1"].contains(testProfile),
                  (1...4096).contains(width), (1...4096).contains(height),
                  testProfile != "template-runtime-v1" || ((64...1280).contains(width) && (64...1280).contains(height))
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
        (context.testProfile == "template-structure-v1" &&
         results == ["structure": .passed, "sourceReconstruction": .passed, "policy": .passed,
                     "runtime": .notChecked, "posterCapture": .notChecked]) || allowsPublication
    }

    var allowsPublication: Bool {
        context.testProfile == "template-runtime-v1" && posterDigest.map(CreatorPersistence.validDigest) == true &&
        results == ["structure": .passed, "sourceReconstruction": .passed, "policy": .passed,
                    "runtime": .passed, "posterCapture": .passed]
    }
}
