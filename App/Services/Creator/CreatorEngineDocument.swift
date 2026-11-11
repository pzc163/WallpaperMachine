import Foundation

/// Future engines are explicit data values, never silently mapped to an executable implementation.
enum CreatorEngine: String, Codable, CaseIterable, Sendable {
    case shaderGLSL = "shader-glsl", three3D = "three-3d", htmlCanvas = "html-canvas"
    case hybridImage = "hybrid-image", scene25D = "scene-25d", audioReactive = "audio-reactive"
    var available: Bool { [.shaderGLSL, .three3D, .htmlCanvas].contains(self) }
}

/// The native shell is reproducible. Only parameter data and the bounded author program vary.
struct CreatorEngineDocument: Sendable, Equatable {
    struct Metadata: Codable, Sendable, Equatable {
        var version = 1
        var engine: CreatorEngine
        var title: String
        var masterID: String? = nil
    }
    var metadata: Metadata
    var parameters: CreatorParameterSchema
    var image: String
    var bufferA: String? = nil
    var engine: CreatorEngine { metadata.engine }
    static let style = "html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}canvas{display:block;width:100%;height:100%}"
    func html() throws -> String {
        try validate()
        let meta = String(decoding: try CreatorPersistence.encode(metadata), as: UTF8.self).replacingOccurrences(of: "<", with: #"\u003c"#)
        let title = metadata.title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let program: String
        if engine == .shaderGLSL {
            program = "<script id=\"wm-image\" type=\"x-shader/x-fragment\">" + image + "</script>" +
                (bufferA.map { "<script id=\"wm-buffer\" type=\"x-shader/x-fragment\">" + $0 + "</script>" } ?? "") +
                "<script src=\"wm-lib://engines/shader-v1.js\"></script>"
        } else {
            program = "<script src=\"wm-lib://three/bundle.js\"></script><script id=\"wm-source\">" + image + "</script><script src=\"wm-lib://engines/three-v1.js\"></script>"
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" + title + "</title><style>" + Self.style + "</style></head><body><canvas id=\"wm-canvas\"></canvas><script id=\"wm-engine\" type=\"application/json\">" + meta + "</script><script id=\"wm-params\" type=\"application/json\">" + (try parameters.json()) + "</script>" + program + "</body></html>"
    }
    func validate() throws {
        guard metadata.version == 1, [.shaderGLSL, .three3D].contains(engine),
              !image.isEmpty, image.utf8.count <= 240 * 1024,
              metadata.masterID.map({ $0.range(of: #"^[a-z0-9-]{1,48}$"#, options: .regularExpression) != nil }) ?? true
        else { throw CreatorRepairIssue.field("$", .unexpected, policy: true) }
        try CreatorBundlePresentation(title: metadata.title, summary: "Procedural engine wallpaper").validate()
        try parameters.validate()
        for source in [image, bufferA].compactMap({ $0 }) {
            guard source.utf8.count <= 240 * 1024, !source.lowercased().contains("</script"),
                  !source.contains("\u{0}"), !source.contains("\u{1b}") else { throw CreatorRepairIssue.field("$", .syntax) }
        }
        if engine == .shaderGLSL {
            for source in [image, bufferA].compactMap({ $0 }) {
                guard source.range(of: #"\bvoid\s+mainImage\s*\("#, options: .regularExpression) != nil,
                      source.range(of: #"(?m)^\s*#\s*(?:version|extension|include|line)\b"#, options: .regularExpression) == nil else { throw CreatorRepairIssue.field("$", .syntax) }
            }
        } else {
            guard bufferA == nil, image.range(of: #"\bfunction\s+setupScene\s*\("#, options: .regularExpression) != nil,
                  image.range(of: #"\bfunction\s+updateScene\s*\("#, options: .regularExpression) != nil else { throw CreatorRepairIssue.field("$", .syntax) }
        }
    }
    static func block(_ id: String, in html: String, type: String? = nil) throws -> String? {
        let suffix = type.map { "\\s+type=\"" + NSRegularExpression.escapedPattern(for: $0) + "\"" } ?? ""
        let pattern = "(?is)<script\\s+id=\"" + id + "\"" + suffix + "\\s*>(.*?)</script\\s*>"
        let regex = try NSRegularExpression(pattern: pattern), text = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: text.length))
        guard matches.count <= 1 else { throw CreatorRepairIssue.field("$", .unexpected, policy: true) }
        return matches.first.map { text.substring(with: $0.range(at: 1)) }
    }
    static func read(_ html: String) throws -> Self? {
        guard let text = try block("wm-engine", in: html, type: "application/json") else { return nil }
        guard case .object(let object) = try CreatorJSON.parse(text), Set(object.keys).isSubset(of: ["version", "engine", "title", "masterID"]) else { throw CreatorRepairIssue.field("$", .unexpected, policy: true) }
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(text.utf8))
        guard let parameters = try CreatorParameterSchema.read(html),
              let image = try block(metadata.engine == .shaderGLSL ? "wm-image" : "wm-source", in: html, type: metadata.engine == .shaderGLSL ? "x-shader/x-fragment" : nil) else { throw CreatorRepairIssue.field("$", .missing) }
        let result = Self(metadata: metadata, parameters: parameters, image: image, bufferA: try block("wm-buffer", in: html, type: "x-shader/x-fragment"))
        try result.validate(); return result
    }
    static func parseCore(_ text: String, engine: CreatorEngine, reference: Self? = nil) throws -> Self {
        guard [.shaderGLSL, .three3D].contains(engine), text.utf8.count <= CreatorCodeOutput.maximumSourceBytes else { throw CreatorRepairIssue.field("$", .resourceBudget, policy: true) }
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("```") {
            let label = engine == .shaderGLSL ? "glsl" : "javascript"
            guard source.hasPrefix("```" + label + "\n") || source.hasPrefix("```" + label + "\r\n"),
                  source.hasSuffix("\n```"), let line = source.firstIndex(of: "\n") else { throw CreatorRepairIssue.field("$", .syntax) }
            source = String(source[source.index(after: line)...].dropLast(4))
        }
        guard !source.contains("```"), !source.contains("<!DOCTYPE"), !source.lowercased().contains("<html") else { throw CreatorRepairIssue.field("$", .syntax) }
        var parameters = reference?.parameters ?? .init(parameters: [], values: [:])
        if source.hasPrefix("/* @param ") {
            guard let end = source.range(of: "*/") else { throw CreatorRepairIssue.field("properties", .syntax) }
            parameters = try CreatorParameterSchema.parse(String(source.dropFirst(10).prefix(upTo: end.lowerBound)))
            source = String(source[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var buffer: String?
        if engine == .shaderGLSL, source.hasPrefix("// @pass BufferA\n") {
            let divider = "\n// @pass Image\n"
            guard source.components(separatedBy: divider).count == 2, let range = source.range(of: divider) else { throw CreatorRepairIssue.field("$", .syntax) }
            buffer = String(source[..<range.lowerBound].dropFirst("// @pass BufferA\n".count))
            source = String(source[range.upperBound...])
        } else if source.hasPrefix("// @pass Image\n") { source = String(source.dropFirst("// @pass Image\n".count)) }
        let result = Self(metadata: .init(engine: engine, title: reference?.metadata.title ?? (engine == .shaderGLSL ? "Shader wallpaper" : "3D wallpaper"), masterID: reference?.metadata.masterID), parameters: parameters, image: source, bufferA: buffer)
        try result.validate(); return result
    }
    var core: String { (bufferA.map { "// @pass BufferA\n" + $0 + "\n// @pass Image\n" } ?? "") + image }
}
