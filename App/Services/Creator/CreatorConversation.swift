import Foundation

/// Local-only conversation and authoritative request ledger; never exported with a wallpaper bundle.
struct CreatorConversation: Codable, Equatable, Sendable {
    struct Ticket: Equatable, Sendable { let id: UUID; let projectID: UUID; let token: UUID }
    enum State: String, Codable, Sendable {
        case generating, repairPending, runtime, sealing, publishing, completed, failed, cancelled, interrupted
        var terminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
    }
    struct Attempt: Codable, Equatable, Sendable {
        let jobID: UUID
        let reservedOutputTokens: Int
        var issue: CreatorRepairIssue? = nil
        var usage: LLMResponse.Usage? = nil
        var draftRevisionID: UUID? = nil
    }
    struct Turn: Codable, Equatable, Sendable {
        let id: UUID
        let token: UUID
        let createdAt: Int64
        let baseRevisionID: UUID?
        let baseRevisionDigest: String?
        let profileID: UUID
        let configurationID: UUID
        let userMessage: String
        let maxRepairs: Int
        let requestBudget: Int
        let tokenBudget: Int
        var state: State = .generating
        var repairCount = 0
        var attempts: [Attempt] = []
        var currentJobID: UUID? = nil
        var resultRevisionID: UUID? = nil
        var failure: CreatorRepairIssue? = nil
        var budgetExhausted = false
        var requestCount: Int { attempts.count }
        var reservedOutputTokens: Int { attempts.reduce(0) { $0 + $1.reservedOutputTokens } }
    }
    var schemaVersion = 1
    let projectID: UUID
    var turns: [Turn] = []

    func validate() throws {
        guard schemaVersion == 1, turns.count <= 64, Set(turns.map(\.id)).count == turns.count,
              turns.filter({ !$0.state.terminal }).count <= 1,
              turns.dropLast().allSatisfy({ $0.state.terminal }) else { throw CreatorPersistence.Failure.invalidRecord }
        for turn in turns {
            guard turn.createdAt >= 0, (0...2).contains(turn.maxRepairs), (0...turn.maxRepairs).contains(turn.repairCount),
                  (1...min(3, 1 + turn.maxRepairs)).contains(turn.requestBudget), (1...100_000).contains(turn.tokenBudget),
                  turn.attempts.count <= turn.requestBudget, Set(turn.attempts.map(\.jobID)).count == turn.attempts.count,
                  turn.attempts.allSatisfy({ (1...100_000).contains($0.reservedOutputTokens) }),
                  turn.reservedOutputTokens <= turn.tokenBudget,
                  !turn.userMessage.isEmpty, turn.userMessage.utf8.count <= 2048,
                  CreatorConversationText.sanitize(turn.userMessage) == turn.userMessage,
                  (turn.baseRevisionID == nil) == (turn.baseRevisionDigest == nil),
                  turn.baseRevisionDigest.map(CreatorPersistence.validDigest) ?? true,
                  turn.state != .completed || turn.resultRevisionID != nil,
                  !turn.budgetExhausted || (turn.state == .failed && !turn.attempts.isEmpty),
                  ![.failed, .cancelled, .interrupted].contains(turn.state) || turn.failure != nil
            else { throw CreatorPersistence.Failure.invalidRecord }
            try turn.failure?.validate()
            for attempt in turn.attempts {
                try attempt.issue?.validate()
                if let usage = attempt.usage {
                    guard [usage.inputTokens, usage.outputTokens, usage.totalTokens, usage.thinkingTokens, usage.cacheReadTokens, usage.cacheWriteTokens]
                        .allSatisfy({ $0.map { (0...100_000_000).contains($0) } ?? true }) else { throw CreatorPersistence.Failure.invalidRecord }
                }
            }
        }
    }
}
