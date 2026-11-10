import Foundation

enum CreatorGenerationFailure: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidRequest, malformedOutput, policyViolation, cancelled, staleInput, busy, storage
    case transport(LLMFailure)

    var description: String {
        switch self {
        case .invalidRequest: return "invalid_request"
        case .malformedOutput: return "malformed_output"
        case .policyViolation: return "policy_violation"
        case .cancelled: return "cancelled"
        case .staleInput: return "stale_input"
        case .busy: return "busy"
        case .storage: return "storage"
        case .transport(let failure): return failure.description
        }
    }
    var debugDescription: String { description }
    static func sanitized(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return .cancelled }
        if let failure = error as? LLMFailure {
            switch failure {
            case .cancelled: return .cancelled
            case .protocolViolation, .truncated, .outputLimit, .streamLimit: return .malformedOutput
            case .refused: return .policyViolation
            case .invalidInput: return .invalidRequest
            case .busy: return .busy
            case .invalidJob: return .staleInput
            default: return .transport(failure)
            }
        }
        if let failure = error as? CreatorPersistence.Failure {
            switch failure {
            case .staleJob, .staleValidation: return .staleInput
            case .busy: return .busy
            default: break
            }
        }
        return .storage
    }
}
