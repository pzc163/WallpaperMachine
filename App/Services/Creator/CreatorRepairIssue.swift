import Foundation

/// Only native categories and catalog field names can enter a repair prompt or durable failure record.
struct CreatorRepairIssue: Codable, Equatable, Error, Sendable, CustomStringConvertible {
    enum Category: String, Codable, Sendable {
        case connection, streamUnsupported, usageUnsupported, contextWindow, incompleteOutput
        case malformedOutput, policyViolation, timeout, network, rateLimited, server, runtime, jsonModeUnsupported
        case unauthorized, refused, cancelled, interrupted, staleInput, budgetExhausted, storage, invalidRequest
    }
    enum Rule: String, Codable, Sendable { case syntax, missing, unexpected, type, range, choice, text, defaultMismatch, resourceBudget }
    struct Field: Codable, Equatable, Sendable { let path: String; let rule: Rule }
    enum RuntimeReason: String, Codable, Sendable { case timeout, pageFailed, invalidCapture, syntax, script, unhandled, shader, resource, policy }
    struct ShaderDiagnostic: Codable, Equatable, Sendable {
        enum Pass: String, Codable, Sendable { case Image, BufferA }
        enum Code: String, Codable, Sendable { case syntax, type, undeclared, link, nonfinite }
        let pass: Pass
        let line: Int
        let code: Code
    }
    let category: Category
    var fields: [Field] = []
    var retryAfter: Double? = nil
    var runtimeReason: RuntimeReason? = nil
    var shaderDiagnostics: [ShaderDiagnostic]? = nil
    var timeoutEvidence: LLMTimeoutEvidence? = nil
    var description: String { category.rawValue }

    var repairable: Bool {
        [.streamUnsupported, .usageUnsupported, .contextWindow, .malformedOutput, .policyViolation, .rateLimited, .server, .runtime, .jsonModeUnsupported].contains(category)
            && (retryAfter.map { $0 <= 30 } ?? true)
    }
    func validate() throws {
        try timeoutEvidence?.validate()
        guard timeoutEvidence == nil || category == .timeout else { throw CreatorPersistence.Failure.invalidRecord }
        var allowed: Set<String> = ["$", "schemaVersion", "templateID", "title", "summary", "parameters", "properties"]
        for parameter in CreatorTemplateCatalog.all.flatMap(\.parameters) {
            allowed.insert("parameters." + parameter.id)
            allowed.insert("properties." + parameter.id)
            allowed.insert("properties." + parameter.id + ".default")
        }
        guard shaderDiagnostics.map({ category == .runtime && runtimeReason == .shader && $0.count <= 4 && $0.allSatisfy { (1...16384).contains($0.line) } }) ?? true,
              fields.count <= 16, fields.allSatisfy({ allowed.contains($0.path) }),
              runtimeReason == nil || category == .runtime,
              retryAfter.map({ category == .rateLimited && $0.isFinite && $0 >= 0 && $0 <= 86_400 }) ?? true
        else { throw CreatorPersistence.Failure.invalidRecord }
    }
    static func field(_ path: String, _ rule: Rule, policy: Bool = false) -> Self {
        Self(category: policy ? .policyViolation : .malformedOutput, fields: [.init(path: path, rule: rule)])
    }
    static func from(_ error: Error) -> Self {
        if let issue = error as? Self { return issue }
        if (error as? LLMFailure) == .truncated { return .init(category: .incompleteOutput) }
        if (error as? LLMFailure) == .refused { return .init(category: .refused) }
        if error is CancellationError || (error as? CreatorRuntimeFailure) == .cancelled { return .init(category: .cancelled) }
        if let error = error as? CreatorRuntimeFailure {
            if let reason = RuntimeReason(rawValue: error.rawValue) { return .init(category: .runtime, runtimeReason: reason) }
            return .init(category: .staleInput)
        }
        let failure = CreatorGenerationFailure.sanitized(error)
        switch failure {
        case .malformedOutput: return .field("$", .syntax)
        case .policyViolation: return .field("$", .unexpected, policy: true)
        case .cancelled: return .init(category: .cancelled)
        case .invalidRequest: return .init(category: .invalidRequest)
        case .staleInput: return .init(category: .staleInput)
        case .transport(let transport):
            switch transport {
            case .deadline(let evidence): return .init(category: .timeout, timeoutEvidence: evidence)
            case .unauthorized, .credentialsUnavailable: return .init(category: .unauthorized)
            case .connectionTimeout: return .init(category: .connection)
            case .usageUnsupported: return .init(category: .usageUnsupported)
            case .contextWindow: return .init(category: .contextWindow)
            case .streamUnsupported: return .init(category: .streamUnsupported)
            case .timeout: return .init(category: .timeout)
            case .network: return .init(category: .network)
            case .rateLimited(let seconds): return .init(category: .rateLimited, retryAfter: seconds.map { min(86_400, max(0, $0)) })
            case .server: return .init(category: .server)
            case .budgetExhausted: return .init(category: .budgetExhausted)
            case .staleProfile, .invalidJob: return .init(category: .staleInput)
            default: return .init(category: .invalidRequest)
            }
        default: return .init(category: .storage)
        }
    }
}
