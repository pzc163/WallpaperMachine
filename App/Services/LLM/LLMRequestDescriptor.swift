import Foundation

/// A pure, nonsecret request description. Only the credential layer attaches authorization.
struct LLMRequestDescriptor: Sendable {
    enum Authentication: Sendable { case bearer, anthropic, google }
    let url: URL
    let headers: [String: String]
    let body: Data
    let authentication: Authentication

    static func make(profile: ProviderProfile, input: LLMRequest, jsonMode: Bool) throws -> Self {
        do { try profile.validate(); try input.validate() } catch { throw LLMFailure.invalidInput }
        guard input.maxOutputTokens <= profile.limits.tokenBudget else { throw LLMFailure.budgetExhausted }
        switch profile.protocolKind {
        case .openaiCompatible: return try OpenAICompatibleCodec.request(profile: profile, input: input, jsonMode: jsonMode)
        case .anthropicMessages: return try AnthropicMessagesCodec.request(profile: profile, input: input)
        case .geminiGenerateContent: return try GeminiGenerateContentCodec.request(profile: profile, input: input)
        }
    }
    static func decoder(for profile: ProviderProfile, requiresJSON: Bool = true) -> any LLMProtocolCodec {
        switch profile.protocolKind {
        case .openaiCompatible: return OpenAICompatibleCodec(allowsLeadingThought: true, requiresJSON: requiresJSON)
        case .anthropicMessages: return AnthropicMessagesCodec(requiresJSON: requiresJSON)
        case .geminiGenerateContent: return GeminiGenerateContentCodec(requiresJSON: requiresJSON)
        }
    }
    static func endpoint(_ profile: ProviderProfile, version: String?, suffix: String, query: [URLQueryItem] = []) throws -> URL {
        guard var parts = URLComponents(string: profile.baseURL) else { throw LLMFailure.invalidInput }
        var segments = parts.path.split(separator: "/").map(String.init)
        guard !segments.contains(".."), !segments.contains(".") else { throw LLMFailure.invalidInput }
        if let version, segments.last != version { segments.append(version) }
        parts.path = "/" + (segments + [suffix]).joined(separator: "/")
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw LLMFailure.invalidInput }
        return url
    }
    static func encoded(_ body: [String: Any]) throws -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= 128 * 1024 else { throw LLMFailure.invalidInput }
        return data
    }
}
