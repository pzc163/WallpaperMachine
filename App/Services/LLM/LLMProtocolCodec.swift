import Foundation

/// Each request has its own value-type decoder. No networking, credential access, disk or UI.
protocol LLMProtocolCodec: Sendable {
    mutating func consume(_ event: SSEParser.Event) throws
    var acceptsJSON: Bool { get }
    mutating func consumeJSON(_ data: Data) throws
    func finish() throws -> LLMResponse
}

extension LLMProtocolCodec {
    var acceptsJSON: Bool { false }
    mutating func consumeJSON(_ data: Data) throws { throw LLMFailure.protocolViolation }
}
