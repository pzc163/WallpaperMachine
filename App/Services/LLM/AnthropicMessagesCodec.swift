import Foundation

struct AnthropicMessagesCodec: LLMProtocolCodec {
    private enum Block: Sendable { case text, thinking }
    private var blocks: [Int: Block] = [:]
    private var seen = Set<Int>()
    private var started = false
    private var stopped = false
    private var done = false
    private var answer = LLMAnswerBuffer(allowsLeadingThought: false)
    private var usage = LLMResponse.Usage()

    init(requiresJSON: Bool = true) { answer.requiresJSON = requiresJSON }

    static func request(profile: ProviderProfile, input: LLMRequest, streaming: Bool = true) throws -> LLMRequestDescriptor {
        let body: [String: Any] = ["model": try input.model(for: profile), "stream": streaming, "max_tokens": input.maxOutputTokens,
            "system": input.systemInstruction, "messages": input.messages.enumerated().map { index, message -> [String: Any] in
                if index == input.messages.count-1, let image = input.thumbnailJPEG { return ["role": message.role.rawValue, "content": [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]], ["type": "text", "text": message.content]]] }
                return ["role": message.role.rawValue, "content": message.content]
            }]
        return .init(url: try LLMRequestDescriptor.endpoint(profile, version: "v1", suffix: "messages"),
                     headers: ["anthropic-version": "2023-06-01"], body: try LLMRequestDescriptor.encoded(body), authentication: .anthropic)
    }
    mutating func consume(_ event: SSEParser.Event) throws {
        guard !done else { throw LLMFailure.protocolViolation }
        let object = try LLMJSON.object(event.data)
        guard let type = object["type"] as? String, type == event.name else { throw LLMFailure.protocolViolation }
        if type == "error" { throw LLMFailure.refused }
        if type == "ping" { return }
        if type == "message_start" {
            guard !started, let message = object["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let content = message["content"] as? [Any], content.isEmpty else { throw LLMFailure.protocolViolation }
            started = true; try mergeUsage(message["usage"]); return
        }
        guard started else { throw LLMFailure.protocolViolation }
        switch type {
        case "content_block_start":
            let index = try blockIndex(object)
            guard !stopped, seen.count < 64, !seen.contains(index), let block = object["content_block"] as? [String: Any]
            else { throw LLMFailure.protocolViolation }
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String else { throw LLMFailure.protocolViolation }
                blocks[index] = .text; try answer.append(text)
            case "thinking":
                blocks[index] = .thinking
                if let text = try LLMJSON.string(block["thinking"]) { answer.appendReasoning(text) }
            case "redacted_thinking": blocks[index] = .thinking
            default: throw LLMFailure.refused
            }
            seen.insert(index)
        case "content_block_delta":
            let index = try blockIndex(object)
            guard !stopped, let block = blocks[index], let delta = object["delta"] as? [String: Any] else { throw LLMFailure.protocolViolation }
            switch (block, delta["type"] as? String) {
            case (.text, "text_delta"):
                guard let text = delta["text"] as? String else { throw LLMFailure.protocolViolation }
                try answer.append(text)
            case (.thinking, "thinking_delta"):
                if let text = try LLMJSON.string(delta["thinking"]) { answer.appendReasoning(text) }
            case (.thinking, "signature_delta"): break
            default: throw LLMFailure.protocolViolation
            }
        case "content_block_stop":
            guard blocks.removeValue(forKey: try blockIndex(object)) != nil else { throw LLMFailure.protocolViolation }
        case "message_delta":
            guard blocks.isEmpty, let delta = object["delta"] as? [String: Any] else { throw LLMFailure.protocolViolation }
            if let reason = try LLMJSON.string(delta["stop_reason"]) {
                guard !stopped else { throw LLMFailure.protocolViolation }
                guard ["end_turn", "stop_sequence"].contains(reason) else { throw reason == "max_tokens" ? LLMFailure.truncated : LLMFailure.refused }
                stopped = true
            }
            try mergeUsage(object["usage"])
        case "message_stop":
            guard stopped, blocks.isEmpty else { throw LLMFailure.truncated }
            done = true
        default: throw LLMFailure.protocolViolation
        }
    }
    private func blockIndex(_ object: [String: Any]) throws -> Int {
        guard let index = try LLMJSON.integer(object["index"]), index < 64 else { throw LLMFailure.protocolViolation }
        return index
    }
    private mutating func mergeUsage(_ value: Any?) throws {
        if let stats = try LLMJSON.dictionary(value) {
            try usage.merge(stats, keys: ["input_tokens": \.inputTokens, "output_tokens": \.outputTokens,
                "cache_read_input_tokens": \.cacheReadTokens, "cache_creation_input_tokens": \.cacheWriteTokens])
        }
    }
    var acceptsJSON: Bool { true }
    mutating func consumeJSON(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "message", object["role"] as? String == "assistant",
              let content = object["content"] as? [[String: Any]], let reason = object["stop_reason"] as? String else { throw LLMFailure.protocolViolation }
        var header = object; header["content"] = [Any]()
        try frame("message_start", ["message": header])
        for (index, block) in content.enumerated() {
            try frame("content_block_start", ["index": index, "content_block": block])
            try frame("content_block_stop", ["index": index])
        }
        try frame("message_delta", ["delta": ["stop_reason": reason], "usage": object["usage"] ?? [:]])
        try frame("message_stop", [:])
    }
    private mutating func frame(_ name: String, _ body: [String: Any]) throws {
        var body = body; body["type"] = name
        try consume(.init(name: name, data: String(decoding: try LLMRequestDescriptor.encoded(body), as: UTF8.self)))
    }
    var progress: LLMStreamProgress {
        .init(phase: answer.receivingContent ? .content : .thinking, characters: answer.receivedCharacters, usage: usage, content: answer.content, reasoning: answer.reasoning, reasoningTruncated: answer.reasoningTruncated)
    }
    func finish() throws -> LLMResponse {
        guard done else { throw LLMFailure.truncated }
        return try answer.finish(usage: usage)
    }
}
