import Foundation

/// Each request has its own value-type decoder. No networking, credential access, disk or UI.
protocol LLMProtocolCodec: Sendable {
    mutating func consume(_ event: SSEParser.Event) throws
    func finish() throws -> LLMResponse
}
