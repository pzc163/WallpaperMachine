import Foundation

/// In-memory evidence from a native snapshot of exactly one validated draft.
struct CreatorRuntimeCapture: Sendable {
    let sourceReport: ValidationReport
    let jpeg: Data
    let metrics: [String: Double]

    func validate() throws {
        try CreatorBundleManifest.validatePoster(jpeg)
        try sourceReport.context.runtime.validate()
        guard sourceReport.allowsPreview, sourceReport.posterDigest == nil
        else { throw CreatorRuntimeFailure.invalidCapture }
        try CreatorPosterMetadata.validate(jpeg: jpeg, metrics: metrics, context: sourceReport.context)
    }
}

enum CreatorRuntimeFailure: String, Error, Sendable, CustomStringConvertible {
    case cancelled, timeout, pageFailed, invalidCapture, staleInput, publicationFailed
    var description: String { rawValue }
}
