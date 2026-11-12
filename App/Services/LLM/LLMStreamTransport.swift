import Foundation

/// One ephemeral URLSession per request, shared by all protocol codecs.
struct LLMStreamTransport: @unchecked Sendable {
    struct Limits: Sendable {
        var maximumBytes = 32 * 1024 * 1024
        var maximumEventBytes = 2 * 1024 * 1024
        var timeout: TimeInterval = 1200
        var firstResponseTimeout: TimeInterval = 60
        var idleTimeout: TimeInterval = 120
        var firstContentTimeout: TimeInterval? = nil
        func validate() throws {
            guard (1...32 * 1024 * 1024).contains(maximumBytes), (1...2 * 1024 * 1024).contains(maximumEventBytes),
                  ([timeout, firstResponseTimeout, idleTimeout] + (firstContentTimeout.map { [$0] } ?? [])).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 7200 }) else { throw LLMFailure.invalidInput }
        }
    }
    private let configuration: URLSessionConfiguration
    let limits: Limits
    private let usesProfilePolicy: Bool
    init(configuration: URLSessionConfiguration = .ephemeral, limits: Limits? = nil) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.limits = limits ?? .init()
        usesProfilePolicy = limits == nil
    }
    func resolved(for profile: ProviderProfile) -> Self {
        guard usesProfilePolicy else { return self }
        let policy = profile.effectiveTimeoutPolicy
        var limits = limits
        limits.timeout = policy.total; limits.firstResponseTimeout = policy.firstResponse
        limits.firstContentTimeout = policy.firstContent; limits.idleTimeout = policy.idle
        return Self(configuration: configuration, limits: limits)
    }
    func perform(_ request: URLRequest, decoder: any LLMProtocolCodec,
                 progress: @escaping @Sendable (LLMStreamProgress) -> Void = { _ in },
                 start: @escaping @Sendable (URLSessionDataTask) async throws -> Void) async throws -> LLMResponse {
        try limits.validate()
        return try await LLMStreamOperation(request: request, decoder: decoder, configuration: configuration, limits: limits, progress: progress).run(start: start)
    }
}
