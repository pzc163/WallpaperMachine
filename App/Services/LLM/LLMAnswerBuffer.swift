import Foundation

/// Discards declared leading thought tags incrementally; JSON string contents remain untouched.
struct LLMAnswerBuffer: Sendable {
    private enum Phase: Sendable { case prefix, thought, answer }
    private var phase = Phase.prefix
    private var marker = ""
    private var text = ""
    let allowsLeadingThought: Bool
    var requiresJSON = true
    private var maximumBytes: Int { requiresJSON ? LLMJSONEnvelope.maximumBytes : 34 * 1024 }

    var receivedCharacters: Int { text.count }
    var receivingContent: Bool { phase == .answer }

    mutating func append(_ fragment: String) throws {
        for character in fragment {
            switch phase {
            case .prefix:
                if marker.isEmpty && character.isWhitespace {
                    text.append(character)
                    guard text.utf8.count <= maximumBytes else { throw LLMFailure.outputLimit }
                    continue
                }
                if marker.isEmpty && (character == "{" || character == "\u{0060}") { phase = .answer; text.append(character); continue }
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
            guard text.utf8.count <= maximumBytes else { throw LLMFailure.outputLimit }
        }
    }
    func finish(usage: LLMResponse.Usage) throws -> LLMResponse {
        guard phase == .answer else { throw LLMFailure.truncated }
        if requiresJSON { _ = try LLMJSON.object(LLMJSONEnvelope.unwrap(text)) }
        return LLMResponse(text: text.trimmingCharacters(in: CharacterSet(charactersIn: " \r\n\t")), usage: usage)
    }
}
