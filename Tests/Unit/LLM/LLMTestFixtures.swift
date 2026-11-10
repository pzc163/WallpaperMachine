import Foundation
import XCTest
@testable import WallpaperMachine

enum LLMTestFixtures {
    static let answer = "{\"title\":\"星空🌙\",\"literal\":\"<think>keep</think>\"}"
    static let key = "fixture-key-never-a-real-secret"
    static func frame(_ object: [String: Any], event: String? = nil) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return Data(((event.map { "event: \($0)\n" } ?? "") + "data: " + text + "\n\n").utf8)
    }
    static func openAI(_ text: String = answer, reason: String = "stop", usage: [String: Any]? = ["prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20], done: Bool = true) throws -> Data {
        var data = try frame(["choices": [["index": 0, "delta": ["content": text, "reasoning_content": "private thought"], "finish_reason": reason]], "usage": NSNull()])
        if let usage { data.append(try frame(["choices": [], "usage": usage])) }
        if done { data.append(Data("data: [DONE]\n\n".utf8)) }
        return data
    }
    static func anthropic(_ text: String = answer) throws -> Data {
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["role": "assistant", "content": [], "usage": ["input_tokens": 12, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "private start"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "private thought"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "private signature"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": "{"]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": String(text.dropFirst())]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_delta", "delta": ["stop_reason": NSNull()], "usage": ["output_tokens": 3]],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 8]],
            ["type": "message_stop"]]
        return try events.reduce(into: Data()) { $0.append(try frame($1, event: $1["type"] as? String)) }
    }
    static func gemini(_ text: String = answer) throws -> Data {
        var data = try frame(["candidates": [["index": 0, "content": ["role": "model", "parts": [["thought": true, "text": "private thought"], ["text": text]]], "finishReason": "STOP"]]])
        data.append(try frame(["candidates": [], "usageMetadata": ["promptTokenCount": 12, "candidatesTokenCount": 8, "totalTokenCount": 24, "thoughtsTokenCount": 4]]))
        return data
    }
    static func body(for kind: ProviderProfile.ProtocolKind) throws -> Data {
        switch kind {
        case .openaiCompatible: return try openAI()
        case .anthropicMessages: return try anthropic()
        case .geminiGenerateContent: return try gemini()
        }
    }
    static func decode(_ data: Data, profile: ProviderProfile, chunkSize: Int = 1) throws -> LLMResponse {
        var parser = SSEParser(), codec = LLMRequestDescriptor.decoder(for: profile)
        for start in stride(from: 0, to: data.count, by: chunkSize) {
            for event in try parser.append(data.subdata(in: start..<min(start + chunkSize, data.count))) { try codec.consume(event) }
        }
        try parser.finish(); return try codec.finish()
    }
    static func profile(_ kind: ProviderProfile.ProtocolKind = .openaiCompatible) -> ProviderProfile {
        ProviderProfile(name: "Fixture", protocolKind: kind, baseURL: "https://fixture.invalid", model: "fixture-model")
    }
    static var input: LLMRequest { .init(system: "Create wallpaper parameters.", messages: [.init(role: .user, content: "星空")], maxOutputTokens: 64) }
}
