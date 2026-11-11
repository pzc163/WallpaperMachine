import Foundation

/// Sanitizes user-authored context, never an error body or an unvalidated model response.
enum CreatorConversationText {
    static func sanitize(_ input: String) -> String {
        var text = input
        let patterns = [
            #"(?i)(?:bearer\s+|(?:api[_ -]?key|authorization|password|secret|token|steamLoginSecure|steamLogin|steamRememberLogin|sessionid|cookie|set-cookie)\s*[:=]\s*)[^\s,;\"'<>]+"#,
            #"(?i)(?:https?|file)://[^\s\"'<>]+"#,
            #"(?<![\p{L}\p{N}])(?:~?/|[A-Za-z]:\\)[^\s\"'<>]+"#,
            #"\b(?:sk-|sk_|AIza)[A-Za-z0-9_\-]+\b"#,
            #"[A-Za-z0-9_+/=\-]{24,}"#
        ]
        for pattern in patterns { text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
        text = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && ![0x2028, 0x2029, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
        }.map(String.init).joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
