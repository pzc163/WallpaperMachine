import Foundation

/// No content, thoughts, endpoints or credentials cross this observation boundary.
struct LLMStreamProgress: Equatable, Sendable {
    enum Phase: Sendable { case connecting, thinking, content }
    var phase: Phase = .connecting
    var characters = 0
    var usage = LLMResponse.Usage()
}
