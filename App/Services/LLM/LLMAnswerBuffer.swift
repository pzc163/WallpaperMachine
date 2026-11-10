import Foundation

/// Discards declared leading thought tags incrementally; JSON string contents remain untouched.
struct LLMAnswerBuffer: Sendable {
    private enum Phase: Sendable { case prefix, thought, answer }
    private var phase = Phase.prefix
    private var marker = ""
    private var text = ""
    let allowsLeadingThought: Bool

    mutating func append(_ fragment: String) throws {
        for character in fragment {
            switch phase {
            case .prefix:
                if marker.isEmpty && character.isWhitespace { continue }
                if marker.isEmpty && character == "{" { phase = .answer; text.append(character); continue }
                marker.append(character)
                guard allowsLeadingThought, "<think>".hasPrefix(marker) else { throw LLMFailure.protocolViolation }
                if marker == "<think>" { marker = ""; phase = .thought }
            case .thought:
                marker.append(character)
                if marker.hasSuffix("</think>") { marker = ""; phase = .prefix }
                else if marker.count > 8 { marker.removeFirst() }
            case .answer:
                text.append(character)
            }
            guard text.utf8.count <= 16 * 1024 else { throw LLMFailure.outputLimit }
        }
    }
    func finish(usage: LLMResponse.Usage) throws -> LLMResponse {
        guard phase == .answer else { throw LLMFailure.truncated }
        _ = try LLMJSON.object(text)
        return LLMResponse(text: text, usage: usage)
    }
}
