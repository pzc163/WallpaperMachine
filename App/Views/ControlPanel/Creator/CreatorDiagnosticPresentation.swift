import Foundation

@MainActor enum CreatorDiagnosticPresentation {
    static func summary(_ issue: CreatorRepairIssue) -> String {
        if let evidence = issue.timeoutEvidence {
            switch evidence.kind {
            case .firstResponse: return L("The server did not return response headers in time.")
            case .firstContent: return L("Connected, but the model produced no thinking or content before the first-content limit.")
            case .idle: return L("The model stream stopped sending data for too long.")
            case .total: return L("The request reached its total time limit, even if the model was still generating.")
            }
        }
        if let diagnostic = issue.diagnostic { return explanation(diagnostic.code) }
        if let reason = issue.runtimeReason {
            switch reason {
            case .timeout: return L("The preview failed its startup or heartbeat deadline. This is not a model request timeout.")
            case .invalidCapture: return L("A valid cover image could not be captured.")
            case .pageFailed: return L("The WebKit page failed to load or its process stopped.")
            case .syntax: return explanation(.syntax)
            case .script: return explanation(.script)
            case .unhandled: return explanation(.unhandled)
            case .shader: return explanation(.shaderCompile)
            case .resource: return L("The generated code exceeded a sandbox resource limit.")
            case .policy: return explanation(.externalResource)
            }
        }
        return CreatorLabels.issue(issue.category)
    }
    static func explanation(_ code: CreatorSourceDiagnostic.Code) -> String {
        switch code {
        case .syntax: L("JavaScript syntax is invalid. Check the indicated line and preceding brackets.")
        case .reference: L("JavaScript referenced an undefined variable or function.")
        case .type: L("JavaScript used a value with the wrong type or an unavailable method.")
        case .range: L("JavaScript exceeded a valid range or recursion limit.")
        case .script: L("The page raised a JavaScript exception.")
        case .unhandled: L("An asynchronous operation rejected without an error handler.")
        case .shaderCompile: L("The GPU rejected a shader. Check the pass and source line below.")
        case .shaderLink: L("The GPU could not link the shader program. Check matching inputs and outputs.")
        case .canvasDimensions: L("Canvas dimensions must be 1–4096 pixels per side, including during resize.")
        case .canvasPixels: L("Canvas area exceeded 2,073,600 pixels. Reset width and height to 1 before resizing.")
        case .canvasCount: L("The code created more than one rendering canvas.")
        case .animationQueue: L("Too many animation callbacks were queued. Use one frame loop.")
        case .unsupportedCanvas: L("OffscreenCanvas is unavailable in this sandbox. Use the host canvas.")
        case .consoleLimit: L("The page exceeded 256 console calls. Remove per-frame logging.")
        case .processMemory: L("The WebContent process exceeded its memory limit. Reduce textures and allocations.")
        case .cpuBudget: L("The preview sustained excessive CPU use. Reduce loops and per-frame work.")
        case .blankFrame: L("The captured frame was black or uniform. Render a visible first frame before validation.")
        case .transparentFrame: L("The captured frame was mostly transparent. Paint an opaque background.")
        case .invalidHTML: L("The HTML document is incomplete or invalid. Include the opening and closing html tags.")
        case .sourceLimit: L("The HTML source exceeded the 256 KiB limit.")
        case .externalResource: L("The offline sandbox blocked an external resource or forbidden element.")
        case .unsupportedScript: L("Use inline classic scripts. Modules and unapproved external scripts are unavailable.")
        }
    }
    static func stage(_ issue: CreatorRepairIssue) -> String {
        switch issue.stage ?? (issue.category == .runtime ? .runtime : [.malformedOutput, .policyViolation].contains(issue.category) ? .staticValidation : .generation) {
        case .generation: L("Model request")
        case .staticValidation: L("Static source validation")
        case .runtime: L("Sandbox runtime validation")
        case .capture: L("Cover capture")
        case .publication: L("Library publication")
        }
    }
    static func advice(_ issue: CreatorRepairIssue) -> String {
        if issue.category == .timeout || issue.category == .connection || issue.category == .network {
            return L("Check model load and server status. Increase the relevant time limit or lower reasoning effort, then retry explicitly. Received code is kept in this session.")
        }
        if issue.category == .runtime || issue.diagnostic != nil {
            return L("Open the indicated source, fix the error and validate again without a model call. Runtime safety limits still apply.")
        }
        return L("Review the field errors, edit the prompt or source, and retry. The last valid revision remains available.")
    }
    static func field(_ field: CreatorRepairIssue.Field) -> String {
        let detail: String
        switch field.rule {
        case .syntax: detail = L("Invalid syntax")
        case .missing: detail = L("Required field missing")
        case .unexpected: detail = L("Unexpected field or forbidden content")
        case .type: detail = L("Incorrect value type")
        case .range: detail = L("Value outside allowed range")
        case .choice: detail = L("Unsupported enum value")
        case .text: detail = L("Invalid or sensitive text")
        case .defaultMismatch: detail = L("Default does not match the parameter")
        case .resourceBudget: detail = L("Resource budget exceeded")
        }
        return field.path + ": " + detail
    }
    static func diagnostics(_ issue: CreatorRepairIssue) -> [CreatorSourceDiagnostic] {
        if let shaders = issue.shaderDiagnostics, !shaders.isEmpty {
            return shaders.map { .init(code: $0.code == .link ? .shaderLink : .shaderCompile, source: $0.pass == .Image ? .Image : .BufferA, line: $0.line) }
        }
        return issue.diagnostic.map { [$0] } ?? []
    }
    static func displayLine(_ item: CreatorSourceDiagnostic, in source: String) -> Int? {
        guard var line = item.line, !source.isEmpty else { return nil }
        let lines = source.components(separatedBy: "\n")
        if item.source == .shader { return nil }
        if item.source == .Image || item.source == .BufferA {
            let marker = "// @pass " + (item.source == .Image ? "Image" : "BufferA")
            if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) { line += index + 1 }
            else if item.source == .BufferA { return nil }
        }
        return (1...lines.count).contains(line) ? line : nil
    }
    static func excerpt(_ item: CreatorSourceDiagnostic, source: String) -> String? {
        guard let line = displayLine(item, in: source) else { return nil }
        let lines = source.components(separatedBy: "\n")
        return (max(1, line - 1)...min(lines.count, line + 1)).map { number in
            "\(number == line ? ">" : " ") \(number): " + String(CreatorConversationText.sanitize(lines[number - 1]).prefix(180))
        }.joined(separator: "\n")
    }
    static func copiedReport(_ issue: CreatorRepairIssue) -> String {
        // Deliberately omits source snippets and all model-authored messages.
        let evidence = (try? CreatorPersistence.encode(issue)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return stage(issue) + "\n" + summary(issue) + "\n" + advice(issue) + "\n" + evidence
    }
}
