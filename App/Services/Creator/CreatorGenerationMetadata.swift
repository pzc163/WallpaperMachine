import Foundation

/// Immutable provenance, not provider authorization or a claim about failed-attempt billing.
struct CreatorGenerationMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let jobID: UUID
    let configurationID: UUID
    let configurationRevision: Int
    let protocolKind: ProviderProfile.ProtocolKind
    let attemptCount: Int
    let reservedOutputTokens: Int
    let usage: LLMResponse.Usage
    let elapsed: TimeInterval
    let baseRevisionDigest: String?
    var iterationID: UUID? = nil
    var repairIndex: Int? = nil

    func validate() throws {
        let counts = [usage.inputTokens, usage.outputTokens, usage.totalTokens, usage.thinkingTokens, usage.cacheReadTokens, usage.cacheWriteTokens]
        guard schemaVersion == 1, configurationRevision > 0, (1...3).contains(attemptCount),
              (1...ProviderProfile.Limits.maximumReservedTokens).contains(reservedOutputTokens), elapsed.isFinite, (0...3600).contains(elapsed),
              counts.allSatisfy({ $0.map { (0...100_000_000).contains($0) } ?? true }),
              baseRevisionDigest.map(CreatorPersistence.validDigest) ?? true,
              (iterationID == nil) == (repairIndex == nil), repairIndex.map({ (0...2).contains($0) }) ?? true
        else { throw CreatorPersistence.Failure.invalidRecord }
    }
}
