import Foundation

/// Removes one whole JSON fence, never searches prose for a usable object.
enum LLMJSONEnvelope {
    static let maximumBytes = 16 * 1024
    static func unwrap(_ text: String) throws -> String {
        guard text.utf8.count <= maximumBytes else { throw LLMFailure.outputLimit }
        let whitespace = CharacterSet(charactersIn: " \r\n\t")
        let trimmed = text.trimmingCharacters(in: whitespace)
        let fence = String(repeating: "\u{0060}", count: 3)
        guard trimmed.hasPrefix(fence) else { return trimmed }
        let lines = trimmed.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count >= 3, [fence, fence + "json"].contains(lines[0]), lines.last == fence,
              !lines.dropFirst().dropLast().contains(where: { $0.trimmingCharacters(in: whitespace).hasPrefix(fence) })
        else { throw LLMFailure.protocolViolation }
        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: whitespace)
    }
}
