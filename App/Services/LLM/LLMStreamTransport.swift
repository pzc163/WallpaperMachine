import Foundation

/// One ephemeral URLSession per request, shared by all protocol codecs.
struct LLMStreamTransport: @unchecked Sendable {
    struct Limits: Sendable {
        var maximumBytes = 1024 * 1024
        var maximumEventBytes = 64 * 1024
        var timeout: TimeInterval = 60
        func validate() throws {
            guard (1...1024 * 1024).contains(maximumBytes), (1...64 * 1024).contains(maximumEventBytes),
                  timeout.isFinite, timeout > 0, timeout <= 300 else { throw LLMFailure.invalidInput }
        }
    }
    private let configuration: URLSessionConfiguration
    let limits: Limits
    init(configuration: URLSessionConfiguration = .ephemeral, limits: Limits = .init()) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.limits = limits
    }
    func perform(_ request: URLRequest, decoder: any LLMProtocolCodec,
                 start: @escaping @Sendable (URLSessionDataTask) async throws -> Void) async throws -> LLMResponse {
        try limits.validate()
        return try await LLMStreamOperation(request: request, decoder: decoder, configuration: configuration, limits: limits).run(start: start)
    }
}
