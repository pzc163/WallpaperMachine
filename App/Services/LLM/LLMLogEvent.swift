import Foundation

/// Diagnostics have no externally supplied strings, request objects or underlying errors.
enum LLMLogEvent: Sendable, CustomStringConvertible {
    case started(attempt: Int), completed(attempts: Int), retry(attempt: Int), failed(LLMFailure)
    var description: String {
        switch self {
        case .started(let attempt): return "creator_llm started attempt=\(attempt)"
        case .completed(let attempts): return "creator_llm completed attempts=\(attempts)"
        case .retry(let attempt): return "creator_llm retry attempt=\(attempt)"
        case .failed(let failure): return "creator_llm failed code=\(failure.description)"
        }
    }
}
