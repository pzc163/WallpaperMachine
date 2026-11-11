import Foundation

/// Plain display metadata; never used as source, a file name, URL or property definition.
struct CreatorBundlePresentation: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    static let titleLimit = 60
    static let summaryLimit = 240
    // A dollar anchor can match before a final newline; this assertion requires the actual end.
    static let textPattern = "^[^\\u0000-\\u001f\\u007f-\\u009f\\u2028-\\u202e\\u2066-\\u2069]+(?![\\s\\S])"

    static func validText(_ value: String, limit: Int) -> Bool {
        (1...limit).contains(value.unicodeScalars.count)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.range(of: textPattern, options: .regularExpression) != nil
    }
    func validate() throws {
        guard Self.validText(title, limit: Self.titleLimit), Self.validText(summary, limit: Self.summaryLimit)
        else { throw CreatorGenerationFailure.malformedOutput }
    }
}
