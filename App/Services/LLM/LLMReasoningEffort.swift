import Foundation

enum LLMReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low, high, max
    // K3 always reasons. Do not send K2's thinking.disabled or unknown provider extensions.
    static func supports(_ model: String, protocolKind: ProviderProfile.ProtocolKind) -> Bool {
        protocolKind == .openaiCompatible && ["kimi-k3", "kimi-k3.1-pro", "kimi-k3.1-pro-highspeed"].contains(model.lowercased())
    }
}
