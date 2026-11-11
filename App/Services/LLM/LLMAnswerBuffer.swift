import Foundation

/// Separates only declared leading thought tags; JSON strings and HTML bodies remain untouched.
struct LLMAnswerBuffer: Sendable {
    private enum Phase: Sendable { case prefix, thought, answer }
    private var phase = Phase.prefix
    private var marker = ""
    private var text = ""
    private var byteCount = 0
    private var characterCount = 0
    private(set) var reasoning = ""
    private var reasoningBytes = 0
    private(set) var reasoningTruncated = false
    var content: String { text }
    static let maximumReasoningBytes = 1024 * 1024

    mutating func appendReasoning(_ fragment: String) {
        guard !reasoningTruncated else { return }
        let remaining = Self.maximumReasoningBytes - reasoningBytes
        if fragment.utf8.count <= remaining { reasoning.append(fragment); reasoningBytes += fragment.utf8.count }
        else {
            var prefix = Data(fragment.utf8.prefix(remaining))
            while !prefix.isEmpty && String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
            reasoning.append(String(decoding: prefix, as: UTF8.self)); reasoningBytes += prefix.count; reasoningTruncated = true
        }
    }
    let allowsLeadingThought: Bool
    var requiresJSON = true
    private var maximumBytes: Int { requiresJSON ? LLMJSONEnvelope.maximumBytes : CreatorCodeOutput.maximumEnvelopeBytes }

    var receivedCharacters: Int { characterCount }
    var receivingContent: Bool { phase == .answer }

    private mutating func appendAnswer(_ value: String) throws {
        let count = value.utf8.count
        guard count <= maximumBytes - byteCount else { throw LLMFailure.outputLimit }
        text.append(value); byteCount += count; characterCount += value.count
    }
    mutating func append(_ fragment: String) throws {
        var index = fragment.startIndex
        while index < fragment.endIndex {
            if phase == .answer { try appendAnswer(String(fragment[index...])); return }
            let character = fragment[index]; index = fragment.index(after: index)
            switch phase {
            case .prefix:
                if marker.isEmpty && character.isWhitespace { try appendAnswer(String(character)); continue }
                if marker.isEmpty && (character == "{" || character == "\u{0060}") {
                    phase = .answer; try appendAnswer(String(character)); continue
                }
                marker.append(character)
                let prefix = marker.lowercased()
                if !requiresJSON && (prefix == "<!doctype html" || prefix == "<html") {
                    phase = .answer; try appendAnswer(marker); marker = ""; continue
                }
                if !requiresJSON && !(allowsLeadingThought && "<think>".hasPrefix(marker)) {
                    phase = .answer; try appendAnswer(marker); marker = ""; continue
                }
                if allowsLeadingThought && marker == "<think>" { marker = ""; phase = .thought; continue }
                guard (allowsLeadingThought && "<think>".hasPrefix(marker))
                    || (!requiresJSON && ["<!doctype html", "<html"].contains(where: { $0.hasPrefix(prefix) }))
                else { throw LLMFailure.protocolViolation }
            case .thought:
                marker.append(character)
                if marker.hasSuffix("</think>") {
                    appendReasoning(String(marker.dropLast(8))); marker = ""; phase = .prefix
                }
                else if marker.count > 8 { appendReasoning(String(marker.removeFirst())) }
            case .answer: break
            }
        }
    }
    func finish(usage: LLMResponse.Usage) throws -> LLMResponse {
        guard phase == .answer else { throw LLMFailure.truncated }
        if requiresJSON { _ = try LLMJSON.object(LLMJSONEnvelope.unwrap(text)) }
        return LLMResponse(text: text.trimmingCharacters(in: CharacterSet(charactersIn: " \r\n\t")), usage: usage)
    }
}
