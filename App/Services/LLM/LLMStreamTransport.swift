import Foundation

/// One ephemeral URLSession per request, shared by all protocol codecs.
struct LLMStreamTransport: @unchecked Sendable {
    struct Limits: Sendable {
        var maximumBytes = 32 * 1024 * 1024
        var maximumEventBytes = 2 * 1024 * 1024
        var timeout: TimeInterval = 300
        var firstResponseTimeout: TimeInterval = 25
        var idleTimeout: TimeInterval = 90
        func validate() throws {
            guard (1...32 * 1024 * 1024).contains(maximumBytes), (1...2 * 1024 * 1024).contains(maximumEventBytes),
                  [timeout, firstResponseTimeout, idleTimeout].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 600 }) else { throw LLMFailure.invalidInput }
        }
    }
    private let configuration: URLSessionConfiguration
    let limits: Limits
    init(configuration: URLSessionConfiguration = .ephemeral, limits: Limits = .init()) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.limits = limits
    }
    func perform(_ request: URLRequest, decoder: any LLMProtocolCodec,
                 progress: @escaping @Sendable (LLMStreamProgress) -> Void = { _ in },
                 start: @escaping @Sendable (URLSessionDataTask) async throws -> Void) async throws -> LLMResponse {
        try limits.validate()
        return try await LLMStreamOperation(request: request, decoder: decoder, configuration: configuration, limits: limits, progress: progress).run(start: start)
    }
}
