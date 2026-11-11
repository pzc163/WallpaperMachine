import Foundation

/// Session-only presentation, deliberately not Codable and never a generation context.
struct CreatorTranscript: Identifiable {
    let id = UUID()
    var progress = LLMStreamProgress()
    var startedAt = Date()
    var thinkingEndedAt: Date?
    var completed = false
    var isThinking: Bool { !completed && thinkingEndedAt == nil }
    var byteCount: Int { progress.content.utf8.count + progress.reasoning.utf8.count }
    mutating func receive(_ value: LLMStreamProgress) {
        progress = value
        if value.phase == .content && thinkingEndedAt == nil { thinkingEndedAt = Date() }
    }
    mutating func finish() { completed = true; if thinkingEndedAt == nil { thinkingEndedAt = Date() } }
}

/// Keeps the final synchronous transport callback available before the async stage transition.
final class CreatorStreamMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = LLMStreamProgress()
    func store(_ update: LLMStreamProgress) { lock.withLock { value = update } }
    var latest: LLMStreamProgress { lock.withLock { value } }
    func clear() { store(.init()) }
}
