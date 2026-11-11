import Foundation

/// Display-only redaction preserves code/newlines. This text never replaces validated bundle bytes.
enum LLMStreamText {
    static func sanitize(_ input: String) -> String {
        var text = input
        for pattern in [
            #"(?i)(?:bearer\s+|(?:api[_ -]?key|authorization|password|secret)\s*[:=]\s*)[^\s,;\"'<>]+"#,
            #"(?i)(?:https?|file)://[^\s\"'<>]+"#,
            #"(?:/Users/|/private/|/Volumes/|~/)[^\s\"'<>]+"#,
            #"\b(?:sk-|sk_|AIza)[A-Za-z0-9_\-]+\b"#
        ] { text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
        return String(text.unicodeScalars.filter {
            (!CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains($0.value))
                && ![0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
        })
    }
}
