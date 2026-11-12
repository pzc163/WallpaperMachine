import Foundation

/// An allowlisted explanation and relative source position; never a page-supplied message or path.
struct CreatorSourceDiagnostic: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case syntax, reference, type, range, script, unhandled, shaderCompile, shaderLink
        case canvasDimensions, canvasPixels, canvasCount, animationQueue, unsupportedCanvas, consoleLimit
        case processMemory, cpuBudget, blankFrame, transparentFrame, invalidHTML, sourceLimit, externalResource, unsupportedScript
    }
    enum Source: String, Codable, Sendable { case indexHTML, authorJS, Image, BufferA, shader }
    let code: Code
    var source: Source? = nil
    var line: Int? = nil
    var column: Int? = nil
    func validate() throws {
        guard line.map({ (1...262_144).contains($0) && source != nil }) ?? true,
              column.map({ (1...262_144).contains($0) && line != nil }) ?? true
        else { throw CreatorPersistence.Failure.invalidRecord }
    }
    static func location(code: Code, html: String, line: Int?, column: Int?) -> Self {
        guard let line, (1...262_144).contains(line) else { return .init(code: code) }
        let lines = html.components(separatedBy: "\n")
        guard line <= lines.count else { return .init(code: code) }
        let column = column.flatMap { (1...262_144).contains($0) ? $0 : nil }
        // Engine-owned wrappers are never presented as author code. Only the known script maps.
        if html.contains("id=\"wm-engine\"") {
            guard let start = html.range(of: "<script id=\"wm-source\">"),
                  let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else { return .init(code: code) }
            let first = html[..<start.upperBound].filter { $0 == "\n" }.count + 1
            let last = html[..<end.lowerBound].filter { $0 == "\n" }.count + 1
            guard (first...last).contains(line) else { return .init(code: code) }
            let prefix = String(html[..<start.upperBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
            return .init(code: code, source: .authorJS, line: line - first + 1,
                         column: line == first ? column.flatMap { $0 > prefix.utf16.count ? $0 - prefix.utf16.count : nil } : column)
        }
        return .init(code: code, source: .indexHTML, line: line, column: column)
    }
    static func fromPage(_ text: String, html: String) -> Self? {
        guard text.utf8.count <= 1024, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let raw = object["code"] as? String, let code = Code(rawValue: raw) else { return nil }
        // Only numeric source positions from our srcdoc can refer to the user's source.
        if object["source"] as? String == "about:srcdoc" {
            let line = (object["line"] as? Int).flatMap { $0 > 1 ? $0 - 1 : nil }
            return location(code: code, html: html, line: line, column: object["column"] as? Int)
        }
        return .init(code: code)
    }
    var safeFilename: String? {
        switch source { case .indexHTML: "index.html"; case .authorJS: "scene.js"; case .Image: "Image.glsl"; case .BufferA: "BufferA.glsl"; case .shader: "shader.glsl"; case nil: nil }
    }
}
