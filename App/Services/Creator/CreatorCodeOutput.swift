import Foundation
import JavaScriptCore

/// A small JSON header followed by one raw HTML block. Source is never JSON-escaped.
enum CreatorCodeOutput {
    static let maximumSourceBytes = 256 * 1024
    static let maximumEnvelopeBytes = maximumSourceBytes * 6 + 2048
    static let templateID = "generated-html-v1"
    struct Output: Sendable { let presentation: CreatorBundlePresentation; let html: Data }
    static func parse(_ text: String) throws -> Output {
        guard text.utf8.count <= maximumEnvelopeBytes else { throw CreatorRepairIssue.field("$", .resourceBudget, policy: true) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<!") || text.lowercased().hasPrefix("<html") || text.hasPrefix("```") {
            let source: String
            if text.hasPrefix("```") {
                guard text.hasPrefix("```html\n") || text.hasPrefix("```html\r\n"), text.hasSuffix("\n```"),
                      let firstLine = text.firstIndex(of: "\n") else { throw CreatorRepairIssue.field("$", .syntax) }
                source = String(text[text.index(after: firstLine)...].dropLast(4))
                guard !source.contains("```") else { throw CreatorRepairIssue.field("$", .syntax) }
            } else { source = text }
            return try rawHTML(source)
        }
        // Compatibility with older JSON-string bundles; paths remain a closed, single-file allowlist.
        if !text.contains("\n<file path=") {
            guard case .object(let object) = try? CreatorJSON.parse(text, maximumBytes: maximumEnvelopeBytes),
                  Set(object.keys) == ["schemaVersion", "title", "summary", "files"], object["schemaVersion"] == .number(2),
                  case .string(let title) = object["title"], case .string(let summary) = object["summary"],
                  case .array(let files) = object["files"], files.count == 1, case .object(let file) = files[0],
                  Set(file.keys) == ["path", "content"], file["path"] == .string("index.html"), case .string(let source) = file["content"]
            else { throw CreatorRepairIssue.field("$", .syntax) }
            let presentation = CreatorBundlePresentation(title: title, summary: summary)
            do { try presentation.validate() } catch { throw CreatorRepairIssue.field("title", .text) }
            let html = Data(source.utf8); try validateHTML(html)
            return Output(presentation: presentation, html: html)
        }
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
    private static func rawHTML(_ source: String) throws -> Output {
        let html = Data(source.utf8); try validateHTML(html)
        var title = "Generated wallpaper"
        if let match = source.range(of: #"(?is)<title>[^<>]{1,120}</title>"#, options: .regularExpression) {
            let value = String(source[match].dropFirst(7).dropLast(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? CreatorBundlePresentation(title: value, summary: "Procedural HTML wallpaper").validate()) != nil { title = value }
        }
        return Output(presentation: .init(title: title, summary: "Procedural HTML wallpaper"), html: html)
    }
    static func validateHTML(_ data: Data) throws {
        guard data.count <= maximumSourceBytes else { throw invalid(.sourceLimit, policy: true) }
        guard (32...maximumSourceBytes).contains(data.count), let source = String(data: data, encoding: .utf8),
              !source.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 27 }),
              source.range(of: #"(?i)<html(?:\s|>)"#, options: .regularExpression) != nil,
              source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix("</html>")
        else { throw invalid(.invalidHTML) }
        // This check improves feedback. The independently enforced iframe/CSP policy remains the boundary.
        guard source.range(of: #"(?i)<\s*(?:iframe|frame|object|embed|applet|base|form|link|audio|video)\b|(?:https?|wss?|file|ftp)\s*:\s*//|/Users/|/private/|/Volumes/"#, options: .regularExpression) == nil
        else { throw invalid(.externalResource, policy: true) }
        _ = try CreatorParameterSchema.read(source)
        if let document = try CreatorEngineDocument.read(source) {
            guard try document.html() == source else { throw CreatorRepairIssue.field("$", .unexpected, policy: true) }
        }
        try checkScriptSyntax(source)
    }
    /// Compiles bounded classic-script bodies without invoking them. The native
    /// parser has no app bindings and never executes model code. Opaque iframe
    /// error events intentionally redact SyntaxError details at runtime.
    private static func checkScriptSyntax(_ html: String) throws {
        let expression = try NSRegularExpression(pattern: #"(?is)<script\b([^>]*)>(.*?)</script\s*>"#)
        let text = html as NSString
        guard let context = JSContext() else {
            throw CreatorRepairIssue.field("$", .syntax)
        }
        for match in expression.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let attributes = text.substring(with: match.range(at: 1))
            let trimmed = attributes.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["id=\"wm-params\" type=\"application/json\"", "id=\"wm-engine\" type=\"application/json\"",
                "id=\"wm-image\" type=\"x-shader/x-fragment\"", "id=\"wm-buffer\" type=\"x-shader/x-fragment\""].contains(trimmed) { continue }
            if CreatorLibrary.assets.keys.contains(where: { trimmed == "src=\"" + $0 + "\"" }), text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard trimmed.isEmpty || trimmed == "id=\"wm-source\"" else {
                // V1 author surface is inline classic scripts only; no module,
                // import map, external source or MIME-dependent execution.
                throw invalid(.unsupportedScript, policy: true)
            }
            let body = text.substring(with: match.range(at: 2))
            let script = JSStringCreateWithUTF8CString(body)
            defer { JSStringRelease(script) }
            var exception: JSValueRef?
            guard JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception) else {
                let value = exception.flatMap { JSValue(jsValueRef: $0, in: context) }
                let relative = value?.forProperty("line")?.toInt32() ?? 0
                let before = text.substring(to: match.range(at: 2).location)
                let line = relative > 0 ? before.filter { $0 == "\n" }.count + Int(relative) : nil
                var issue = CreatorRepairIssue.field("$", .syntax)
                issue.stage = .staticValidation
                issue.diagnostic = .location(code: .syntax, html: html, line: line, column: nil)
                throw issue
            }
        }
    }
    private static func invalid(_ code: CreatorSourceDiagnostic.Code, policy: Bool = false) -> CreatorRepairIssue {
        var issue = CreatorRepairIssue.field("$", policy ? .unexpected : .syntax, policy: policy)
        issue.diagnostic = .init(code: code)
        return issue
    }
    static func specification(projectID: UUID, html: Data) throws -> CreatorTemplate.Specification {
        try validateHTML(html)
        let source = String(decoding: html, as: UTF8.self)
        let schema = try CreatorParameterSchema.read(source)
        return .init(projectID: projectID, kind: .code, parameters: schema?.values, codeDigest: CreatorPersistence.hash(html), libraryDigest: try CreatorLibrary.digest(for: source))
    }
    static func files(specification: CreatorTemplate.Specification, html: Data?) throws -> [String: Data] {
        guard specification.kind == .code, specification.version == 1, specification.hue == 220, specification.speed == 0.5,
              specification.templateID == nil, specification.rendererRevision == nil,
              let html, specification.codeDigest == CreatorPersistence.hash(html) else { throw CreatorPersistence.Failure.invalidRecord }
        try validateHTML(html)
        let source = String(decoding: html, as: UTF8.self), schema = try CreatorParameterSchema.read(source)
        guard specification.parameters == schema?.values, specification.libraryDigest == (try CreatorLibrary.digest(for: source)) else { throw CreatorPersistence.Failure.invalidRecord }
        return ["index.html": html, "project.json": try JSONSerialization.data(withJSONObject:
            ["title": "Generated wallpaper", "type": "web", "file": "index.html", "general": ["properties": schema?.properties ?? [:]]], options: [.sortedKeys, .withoutEscapingSlashes])]
    }
}
