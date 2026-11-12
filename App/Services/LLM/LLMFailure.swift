import Foundation

/// Only allowlisted codes cross the transport boundary; never carry response bodies, URLs or keys.
enum LLMFailure: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case deadline(LLMTimeoutEvidence)
    case connectionTimeout, streamUnsupported, usageUnsupported, contextWindow
    case invalidInput, credentialsUnavailable, staleProfile, invalidJob, busy, cancelled, timeout, network
    case unauthorized, rateLimited(retryAfter: Double?), server(Int), http(Int), redirectRejected
    case protocolViolation, truncated, refused, streamLimit, outputLimit, budgetExhausted, jsonModeUnsupported

    var description: String {
        switch self {
        case .deadline(let evidence): return "timeout_\(evidence.kind.rawValue)"
        case .usageUnsupported: return "usage_unsupported"
        case .contextWindow: return "context_window"
        case .connectionTimeout: return "connection_timeout"
        case .streamUnsupported: return "stream_unsupported"
        case .invalidInput: return "invalid_input"
        case .credentialsUnavailable: return "credentials_unavailable"
        case .staleProfile: return "stale_profile"
        case .invalidJob: return "invalid_job"
        case .busy: return "busy"
        case .cancelled: return "cancelled"
        case .timeout: return "timeout"
        case .network: return "network"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate_limited"
        case .server(let status): return "server_\(status)"
        case .http(let status): return "http_\(status)"
        case .redirectRejected: return "redirect_rejected"
        case .protocolViolation: return "protocol_violation"
        case .truncated: return "truncated"
        case .refused: return "refused"
        case .streamLimit: return "stream_limit"
        case .outputLimit: return "output_limit"
        case .budgetExhausted: return "budget_exhausted"
        case .jsonModeUnsupported: return "json_mode_unsupported"
        }
    }
    var debugDescription: String { description }
    static func sanitized(_ error: Error) -> LLMFailure {
        if let failure = error as? LLMFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .timedOut { return .timeout }
            if error.code == .cancelled { return .cancelled }
        }
        return .network
    }
}
