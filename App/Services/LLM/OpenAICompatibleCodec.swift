import Foundation

struct OpenAICompatibleCodec: LLMProtocolCodec {
    private var answer: LLMAnswerBuffer
    private var usage = LLMResponse.Usage()
    private var stopped = false
    private var done = false

    init(allowsLeadingThought: Bool, requiresJSON: Bool = true) { answer = LLMAnswerBuffer(allowsLeadingThought: allowsLeadingThought, requiresJSON: requiresJSON) }
    static func request(profile: ProviderProfile, input: LLMRequest, jsonMode: Bool, streaming: Bool = true) throws -> LLMRequestDescriptor {
        let basePath = URLComponents(string: profile.baseURL)?.path ?? ""
        let url = try LLMRequestDescriptor.endpoint(profile, version: basePath.isEmpty || basePath == "/" ? "v1" : nil, suffix: "chat/completions")
        var body: [String: Any] = ["model": try input.model(for: profile), "stream": streaming,
            "messages": [["role": "system", "content": input.systemInstruction]] + input.messages.enumerated().map { index, message -> [String: Any] in
                if index == input.messages.count-1, let image = input.thumbnailJPEG { return ["role": message.role.rawValue, "content": [["type": "text", "text": message.content], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString(), "detail": "low"]]]] }
                return ["role": message.role.rawValue, "content": message.content]
            }]
        if !input.nativeOutputLimit { body["max_tokens"] = input.maxOutputTokens }
        let mode = profile.capabilities.jsonMode ?? .automatic
        if input.requiresJSON, jsonMode, mode != .disabled {
            if mode == .schema || (mode == .automatic && input.structuredOutput != nil) {
                guard let output = input.structuredOutput else { throw LLMFailure.invalidInput }
                body["response_format"] = ["type": "json_schema", "json_schema": [
                    "name": output.name, "strict": true, "schema": try output.object()]]
            } else {
                body["response_format"] = ["type": "json_object"]
            }
        }
        if streaming && profile.capabilities.requestsUsage { body["stream_options"] = ["include_usage": true] }
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
            if let reasoning = try LLMJSON.string(delta["reasoning_content"]) { answer.appendReasoning(reasoning) }
            if let content = delta["content"], !(content is NSNull) {
                if let text = content as? String { try answer.append(text) }
                else if let blocks = content as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            guard let text = block["text"] as? String else { throw LLMFailure.protocolViolation }
                            try answer.append(text)
                        case "thinking", "reasoning":
                            if let thought = try LLMJSON.string(block["thinking"] ?? block["text"]) { answer.appendReasoning(thought) }
                        case "redacted_thinking": break
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
    var acceptsJSON: Bool { true }
    mutating func consumeJSON(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil, let choices = object["choices"] as? [[String: Any]], choices.count == 1,
              let message = choices[0]["message"] as? [String: Any], message["role"] as? String == "assistant",
              let reason = choices[0]["finish_reason"] as? String else { throw LLMFailure.protocolViolation }
        var adapted = choices[0]; adapted["delta"] = message; adapted["message"] = nil
        adapted["index"] = 0; adapted["finish_reason"] = reason
        var frame = object; frame["choices"] = [adapted]
        try consume(.init(name: "message", data: String(decoding: try LLMRequestDescriptor.encoded(frame), as: UTF8.self)))
        try consume(.init(name: "message", data: "[DONE]"))
    }
    var progress: LLMStreamProgress {
        .init(phase: answer.receivingContent ? .content : .thinking, characters: answer.receivedCharacters, usage: usage, content: answer.content, reasoning: answer.reasoning, reasoningTruncated: answer.reasoningTruncated)
    }
    func finish() throws -> LLMResponse {
        guard done, stopped else { throw LLMFailure.truncated }
        return try answer.finish(usage: usage)
    }
}
