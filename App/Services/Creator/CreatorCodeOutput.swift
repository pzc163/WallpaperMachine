import Foundation
import JavaScriptCore

/// A small JSON header followed by one raw HTML block. Source is never JSON-escaped.
enum CreatorCodeOutput {
    static let maximumSourceBytes = 32 * 1024
    static let templateID = "generated-html-v1"
    struct Output: Sendable { let presentation: CreatorBundlePresentation; let html: Data }
    static func parse(_ text: String) throws -> Output {
        guard text.utf8.count <= maximumSourceBytes + 2048 else { throw CreatorRepairIssue.field("$", .resourceBudget, policy: true) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "\n<file path=\"index.html\">\n", end = "\n</file>"
        guard let split = text.range(of: marker), text.hasSuffix(end), text.components(separatedBy: marker).count == 2 else {
            throw CreatorRepairIssue.field("$", .syntax)
        }
        let header = String(text[..<split.lowerBound])
        guard case .object(let object) = try? CreatorJSON.parse(header), Set(object.keys) == ["schemaVersion", "title", "summary"],
              object["schemaVersion"] == .number(2), case .string(let title) = object["title"], case .string(let summary) = object["summary"]
        else { throw CreatorRepairIssue.field("$", .unexpected) }
        let presentation = CreatorBundlePresentation(title: title, summary: summary)
        do { try presentation.validate() } catch { throw CreatorRepairIssue.field("title", .text) }
        let source = String(text[split.upperBound...].dropLast(end.count))
        guard !source.contains("</file>"), !source.contains("<file ") else { throw CreatorRepairIssue.field("$", .syntax) }
        let html = Data(source.utf8); try validateHTML(html)
        return Output(presentation: presentation, html: html)
    }
    static func validateHTML(_ data: Data) throws {
        guard (32...maximumSourceBytes).contains(data.count), let source = String(data: data, encoding: .utf8),
              !source.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 27 }),
              source.range(of: #"(?i)<html(?:\s|>)"#, options: .regularExpression) != nil,
              source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix("</html>")
        else { throw CreatorRepairIssue.field("$", .syntax) }
        // This check improves feedback. The independently enforced iframe/CSP policy remains the boundary.
        guard source.range(of: #"(?i)<\s*(?:iframe|frame|object|embed|applet|base|form|link|audio|video)\b|(?:https?|wss?|file|ftp)\s*:\s*//|/Users/|/private/|/Volumes/"#, options: .regularExpression) == nil
        else { throw CreatorRepairIssue.field("$", .unexpected, policy: true) }
        try checkScriptSyntax(source)
    }
    /// Compiles bounded classic-script bodies without invoking them. The native
    /// parser has no app bindings and never executes model code. Opaque iframe
    /// error events intentionally redact SyntaxError details at runtime.
    private static func checkScriptSyntax(_ html: String) throws {
        let expression = try NSRegularExpression(pattern: #"(?is)<script\b([^>]*)>(.*?)</script\s*>"#)
        let text = html as NSString
        guard let context = JSContext(), let constructor = context.objectForKeyedSubscript("Function") else {
            throw CreatorRepairIssue.field("$", .syntax)
        }
        for match in expression.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let attributes = text.substring(with: match.range(at: 1))
            guard attributes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // V1 author surface is inline classic scripts only; no module,
                // import map, external source or MIME-dependent execution.
                throw CreatorRepairIssue.field("$", .unexpected, policy: true)
            }
            context.exception = nil
            _ = constructor.construct(withArguments: [text.substring(with: match.range(at: 2))])
            guard context.exception == nil else { throw CreatorRepairIssue.field("$", .syntax) }
        }
    }
    static func specification(projectID: UUID, html: Data) throws -> CreatorTemplate.Specification {
        try validateHTML(html)
        return .init(projectID: projectID, kind: .code, codeDigest: CreatorPersistence.hash(html))
    }
    static func files(specification: CreatorTemplate.Specification, html: Data?) throws -> [String: Data] {
        guard specification.kind == .code, specification.version == 1, specification.hue == 220, specification.speed == 0.5,
              specification.templateID == nil, specification.parameters == nil, specification.rendererRevision == nil,
              let html, specification.codeDigest == CreatorPersistence.hash(html) else { throw CreatorPersistence.Failure.invalidRecord }
        try validateHTML(html)
        return ["index.html": html, "project.json": try JSONSerialization.data(withJSONObject:
            ["title": "Generated wallpaper", "type": "web", "file": "index.html", "general": ["properties": [:]]], options: [.sortedKeys, .withoutEscapingSlashes])]
    }
}
