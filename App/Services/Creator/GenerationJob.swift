import Foundation

/// Durable generation fencing; raw partial output never enters revision or library directories.
struct GenerationJob: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case generating, staged, committing, completed, cancelled, interrupted }
    struct Ticket: Equatable, Sendable {
        let id: UUID
        let projectID: UUID
        let cancellationToken: UUID
    }
    let schemaVersion: Int
    let id: UUID
    let projectID: UUID
    let baseRevisionID: UUID?
    var state: State
    var attemptCount: Int
    let requestBudget: Int
    let tokenBudget: Int
    let cancellationToken: UUID
    let createdAt: Int64
    var candidateRevisionID: UUID?
    var candidateDigest: String?
    var reservedOutputTokens: Int? = nil

    var ticket: Ticket { Ticket(id: id, projectID: projectID, cancellationToken: cancellationToken) }
    var isTerminal: Bool { [.completed, .cancelled, .interrupted].contains(state) }

    func validate() throws {
        guard schemaVersion == 1, (1...3).contains(requestBudget), (1...100_000).contains(tokenBudget),
              (0...requestBudget).contains(attemptCount), createdAt >= 0,
              reservedOutputTokens.map({ (0...tokenBudget).contains($0) }) ?? true,
              (candidateRevisionID == nil) == (candidateDigest == nil),
              candidateDigest.map(CreatorPersistence.validDigest) ?? true,
              ![.staged, .committing, .completed].contains(state) || candidateRevisionID != nil
        else { throw CreatorPersistence.Failure.invalidRecord }
    }
}
