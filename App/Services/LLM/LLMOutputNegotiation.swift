import Foundation

enum LLMOutputNegotiation {
    typealias Mode = ProviderProfile.Capabilities.JSONMode
    static func automatic(_ profile: ProviderProfile) -> Bool {
        profile.protocolKind == .openaiCompatible && (profile.capabilities.jsonMode ?? .automatic) == .automatic
    }
    static func initial(_ profile: ProviderProfile, input: LLMRequest, override: Mode? = nil) -> Mode {
        let mode = override ?? profile.capabilities.jsonMode ?? .automatic
        return mode == .automatic ? (input.structuredOutput == nil ? .required : .schema) : mode
    }
    static func next(_ mode: Mode) -> Mode? {
        switch mode { case .schema: .required; case .required: .disabled; default: nil }
    }
    static func formatFailure(_ error: Error) -> Bool {
        if let failure = error as? LLMFailure { return [.jsonModeUnsupported, .protocolViolation].contains(failure) }
        if let issue = error as? CreatorRepairIssue {
            return [.malformedOutput, .policyViolation].contains(issue.category) && !issue.fields.isEmpty
                && issue.fields.allSatisfy { [.syntax, .missing, .unexpected, .type].contains($0.rule) }
        }
        return false
    }
}
