import Foundation

struct OpenAICompatibleCodec: LLMProtocolCodec {
    private var answer: LLMAnswerBuffer
    private var usage = LLMResponse.Usage()
    private var stopped = false
    private var done = false

    init(allowsLeadingThought: Bool, requiresJSON: Bool = true) { answer = LLMAnswerBuffer(allowsLeadingThought: allowsLeadingThought, requiresJSON: requiresJSON) }
    static func request(profile: ProviderProfile, input: LLMRequest, jsonMode: Bool) throws -> LLMRequestDescriptor {
        let basePath = URLComponents(string: profile.baseURL)?.path ?? ""
        let url = try LLMRequestDescriptor.endpoint(profile, version: basePath.isEmpty || basePath == "/" ? "v1" : nil, suffix: "chat/completions")
        var body: [String: Any] = ["model": profile.model, "stream": true, "max_tokens": input.maxOutputTokens,
            "messages": [["role": "system", "content": input.systemInstruction]] + input.messages.map { ["role": $0.role.rawValue, "content": $0.content] }]
        let mode = profile.capabilities.jsonMode ?? .automatic
        if jsonMode, mode != .disabled {
            if mode == .schema || (mode == .automatic && input.structuredOutput != nil) {
                guard let output = input.structuredOutput else { throw LLMFailure.invalidInput }
                body["response_format"] = ["type": "json_schema", "json_schema": [
                    "name": output.name, "strict": true, "schema": try output.object()]]
            } else {
                body["response_format"] = ["type": "json_object"]
            }
        }
        if profile.capabilities.requestsUsage { body["stream_options"] = ["include_usage": true] }
        return .init(url: url, headers: [:], body: try LLMRequestDescriptor.encoded(body), authentication: .bearer)
    }
    mutating func consume(_ event: SSEParser.Event) throws {
        guard !done, event.name == "message" else { throw LLMFailure.protocolViolation }
        if event.data == "[DONE]" {
            guard stopped else { throw LLMFailure.truncated }
            done = true; return
        }
        let object = try LLMJSON.object(event.data)
        if object["error"] != nil { throw LLMFailure.refused }
        if let stats = try LLMJSON.dictionary(object["usage"]) {
            try usage.merge(stats, keys: ["prompt_tokens": \.inputTokens, "completion_tokens": \.outputTokens, "total_tokens": \.totalTokens])
            if let details = try LLMJSON.dictionary(stats["completion_tokens_details"]) {
                try usage.merge(details, keys: ["reasoning_tokens": \.thinkingTokens])
            }
            if let details = try LLMJSON.dictionary(stats["prompt_tokens_details"]) {
                try usage.merge(details, keys: ["cached_tokens": \.cacheReadTokens])
            }
        }
        guard let choices = object["choices"] as? [[String: Any]] else { throw LLMFailure.protocolViolation }
        var selected = false
        for choice in choices {
            guard let index = try LLMJSON.integer(choice["index"]) else { throw LLMFailure.protocolViolation }
            if index != 0 { continue }
            guard !selected, !stopped else { throw LLMFailure.protocolViolation }
            selected = true
            guard let delta = try LLMJSON.dictionary(choice["delta"]) else { throw LLMFailure.protocolViolation }
            if delta["tool_calls"] != nil || delta["function_call"] != nil { throw LLMFailure.refused }
            if let refusal = try LLMJSON.string(delta["refusal"]), !refusal.isEmpty { throw LLMFailure.refused }
            if let content = delta["content"], !(content is NSNull) {
                if let text = content as? String { try answer.append(text) }
                else if let blocks = content as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            guard let text = block["text"] as? String else { throw LLMFailure.protocolViolation }
                            try answer.append(text)
                        case "thinking", "reasoning", "redacted_thinking": break
                        default: throw LLMFailure.protocolViolation
                        }
                    }
                } else { throw LLMFailure.protocolViolation }
            }
            // reasoning_content and other explicit non-content fields never enter the answer.
            if let reason = try LLMJSON.string(choice["finish_reason"]) {
                guard reason == "stop" else { throw reason == "length" ? LLMFailure.truncated : LLMFailure.refused }
                stopped = true
            }
        }
    }
    func finish() throws -> LLMResponse {
        guard done, stopped else { throw LLMFailure.truncated }
        return try answer.finish(usage: usage)
    }
}
