import Foundation

/// Ephemeral model-authored text, never persisted or formatted into logs. Provider redacts before UI delivery.
struct LLMStreamProgress: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Phase: Sendable { case connecting, waiting, thinking, content }
    var phase: Phase = .connecting
    var characters = 0
    var usage = LLMResponse.Usage()
    var content = ""
    var reasoning = ""
    var reasoningTruncated = false
    var description: String { "LLMStreamProgress(phase: \(phase), characters: \(characters), text: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
