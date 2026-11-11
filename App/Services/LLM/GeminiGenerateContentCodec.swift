import CoreFoundation
import Foundation

struct GeminiGenerateContentCodec: LLMProtocolCodec {
    private var stopped = false
    private var answer = LLMAnswerBuffer(allowsLeadingThought: false)
    private var usage = LLMResponse.Usage()

    init(requiresJSON: Bool = true) { answer.requiresJSON = requiresJSON }

    static func request(profile: ProviderProfile, input: LLMRequest, streaming: Bool = true) throws -> LLMRequestDescriptor {
        var configuration: [String: Any] = ["responseMimeType": input.requiresJSON ? "application/json" : "text/plain"]
        if !input.nativeOutputLimit { configuration["maxOutputTokens"] = input.maxOutputTokens }
        let body: [String: Any] = ["systemInstruction": ["parts": [["text": input.systemInstruction]]],
            "generationConfig": configuration,
            "contents": input.messages.map { ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] }]
        return .init(url: try LLMRequestDescriptor.endpoint(profile, version: "v1beta", suffix: "models/\(profile.model):" + (streaming ? "streamGenerateContent" : "generateContent"), query: streaming ? [.init(name: "alt", value: "sse")] : []),
                     headers: [:], body: try LLMRequestDescriptor.encoded(body), authentication: .google)
    }
    mutating func consume(_ event: SSEParser.Event) throws {
        guard event.name == "message" else { throw LLMFailure.protocolViolation }
        let object = try LLMJSON.object(event.data)
        if object["error"] != nil { throw LLMFailure.refused }
        if let feedback = try LLMJSON.dictionary(object["promptFeedback"]), feedback["blockReason"] != nil { throw LLMFailure.refused }
        if let stats = try LLMJSON.dictionary(object["usageMetadata"]) {
            try usage.merge(stats, keys: ["promptTokenCount": \.inputTokens, "candidatesTokenCount": \.outputTokens,
                "totalTokenCount": \.totalTokens, "thoughtsTokenCount": \.thinkingTokens, "cachedContentTokenCount": \.cacheReadTokens])
        }
        let candidates = object["candidates"] as? [[String: Any]] ?? []
        if candidates.isEmpty {
            guard stopped, object["usageMetadata"] != nil else { throw LLMFailure.refused }
            return
        }
        var selected = false
        for candidate in candidates {
            let index = try LLMJSON.integer(candidate["index"]) ?? 0
            if index != 0 { continue }
            guard !selected else { throw LLMFailure.protocolViolation }
            selected = true
            if let content = try LLMJSON.dictionary(candidate["content"]) {
                guard !stopped, let parts = content["parts"] as? [[String: Any]] else { throw LLMFailure.protocolViolation }
                for part in parts {
                    if let thought = part["thought"] {
                        guard let number = thought as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw LLMFailure.protocolViolation }
                        if number.boolValue {
                            if let text = try LLMJSON.string(part["text"]) { answer.appendReasoning(text) }
                            continue
                        }
                    }
                    if let text = try LLMJSON.string(part["text"]) { try answer.append(text) }
                    else if part["thoughtSignature"] == nil { throw LLMFailure.refused }
                }
            }
            if let reason = try LLMJSON.string(candidate["finishReason"]) {
                guard !stopped else { throw LLMFailure.protocolViolation }
                guard reason == "STOP" else { throw reason == "MAX_TOKENS" ? LLMFailure.truncated : LLMFailure.refused }
                stopped = true
            }
        }
    }
    var acceptsJSON: Bool { true }
    mutating func consumeJSON(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw LLMFailure.protocolViolation }
        try consume(.init(name: "message", data: text))
    }
    var progress: LLMStreamProgress {
        .init(phase: answer.receivingContent ? .content : .thinking, characters: answer.receivedCharacters, usage: usage, content: answer.content, reasoning: answer.reasoning, reasoningTruncated: answer.reasoningTruncated)
    }
    func finish() throws -> LLMResponse {
        guard stopped else { throw LLMFailure.truncated }
        return try answer.finish(usage: usage)
    }
}
