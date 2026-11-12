import Foundation

/// Persisted only when customized. Old profiles keep their canonical credential-binding bytes.
struct LLMTimeoutPolicy: Codable, Equatable, Sendable {
    var firstResponse: TimeInterval
    var firstContent: TimeInterval
    var idle: TimeInterval
    var total: TimeInterval
    static let cloud = Self(firstResponse: 60, firstContent: 180, idle: 120, total: 1200)
    static let local = Self(firstResponse: 300, firstContent: 600, idle: 300, total: 3600)

    func validate() throws {
        guard [firstResponse, firstContent, idle].allSatisfy({ $0.isFinite && (5...1800).contains($0) && $0 <= total }),
              total.isFinite, (60...7200).contains(total) else { throw CreatorPersistence.Failure.invalidRecord }
    }
}

/// Numeric evidence only: safe for durable reports, repair context and logs.
struct LLMTimeoutEvidence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case firstResponse, firstContent, idle, total }
    let kind: Kind
    let elapsed: TimeInterval
    let limit: TimeInterval
    let receivedBytes: Int
    let receivedCharacters: Int
    func validate() throws {
        guard elapsed.isFinite, (0...86_400).contains(elapsed), limit.isFinite, (0...7200).contains(limit),
              (0...32 * 1024 * 1024).contains(receivedBytes), (0...32 * 1024 * 1024).contains(receivedCharacters)
        else { throw CreatorPersistence.Failure.invalidRecord }
    }
}

/// Monotonic timestamps are supplied by the transport; tests can advance hours without sleeping.
struct LLMDeadlineTracker: Sendable {
    let began: TimeInterval
    let limits: LLMStreamTransport.Limits
    private(set) var responseAt: TimeInterval?
    private(set) var contentAt: TimeInterval?
    private var activityAt: TimeInterval?
    private var bytes = 0
    private var characters = 0
    mutating func response(at now: TimeInterval) { responseAt = now; activityAt = now }
    mutating func received(bytes count: Int, characters: Int, effectiveContent: Bool, at now: TimeInterval) {
        if count > 0 { bytes = min(limits.maximumBytes, bytes + count); activityAt = now }
        self.characters = min(32 * 1024 * 1024, max(self.characters, characters))
        if effectiveContent && contentAt == nil { contentAt = now }
    }
    private var phase: (LLMTimeoutEvidence.Kind, TimeInterval, TimeInterval) {
        guard let responseAt else { return (.firstResponse, began, limits.firstResponseTimeout) }
        if contentAt == nil, let firstContent = limits.firstContentTimeout { return (.firstContent, responseAt, firstContent) }
        return (.idle, activityAt ?? responseAt, limits.idleTimeout)
    }
    var nextDeadline: TimeInterval { min(began + limits.timeout, phase.1 + phase.2) }
    func failure(at now: TimeInterval) -> LLMTimeoutEvidence? {
        let current = phase
        let reachedTotal = began + limits.timeout <= current.1 + current.2
        guard now >= nextDeadline else { return nil }
        return .init(kind: reachedTotal ? .total : current.0, elapsed: min(86_400, max(0, now - began)),
                     limit: reachedTotal ? limits.timeout : current.2, receivedBytes: bytes, receivedCharacters: characters)
    }
}
