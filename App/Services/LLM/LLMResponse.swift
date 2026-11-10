import Foundation

/// A complete answer, not a validated template contract or an executable revision.
struct LLMResponse: Equatable, Sendable {
    var text: String
    var usage = Usage()
    struct Usage: Equatable, Sendable {
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var thinkingTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        var isUnknown: Bool { inputTokens == nil && outputTokens == nil && totalTokens == nil }

        mutating func merge(_ object: [String: Any], keys: [String: WritableKeyPath<Self, Int?>]) throws {
            for (key, path) in keys {
                guard let value = try LLMJSON.integer(object[key]) else { continue }
                if let previous = self[keyPath: path], value < previous { throw LLMFailure.protocolViolation }
                self[keyPath: path] = value
            }
        }
    }
}
