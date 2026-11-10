import Foundation

extension CreatorRevisionStore {
    nonisolated func conversationURL(_ projectID: UUID) -> URL { projectURL(projectID).appendingPathComponent("conversation.json") }
    nonisolated func iterationLeaseURL(_ ticket: CreatorConversation.Ticket) -> URL {
        projectURL(ticket.projectID).appendingPathComponent(".iteration-" + CreatorPersistence.uuidName(ticket.id) + ".lease")
    }
    func conversation(projectID: UUID) throws -> CreatorConversation { try locked { try readConversation(projectID) } }
    func readConversation(_ projectID: UUID) throws -> CreatorConversation {
        _ = try readProject(projectID)
        let path = conversationURL(projectID)
        guard CreatorPersistence.exists(path) else { return .init(projectID: projectID) }
        let document = try CreatorPersistence.read(CreatorConversation.self, at: path)
        try document.validate()
        guard document.projectID == projectID else { throw CreatorPersistence.Failure.invalidRecord }
        return document
    }
    func saveConversation(_ document: CreatorConversation) throws {
        try document.validate()
        try CreatorPersistence.write(document, to: conversationURL(document.projectID))
    }

    func beginIteration(projectID: UUID, base: CreatorPromptBuilder.Base?, profile: ProviderProfile,
                        message: String, maxRepairs: Int) throws -> CreatorConversation.Ticket {
        try locked {
            try Task.checkCancellation()
            guard (0...2).contains(maxRepairs), CreatorConversationText.sanitize(message) == message else { throw CreatorGenerationFailure.invalidRequest }
            try profile.validate()
            guard !message.isEmpty, message.utf8.count <= 2048, try readConversation(projectID).turns.count < 64
            else { throw CreatorPersistence.Failure.tooLarge }
            if let base {
                let checked = try validatedSnapshot(projectID: projectID, revisionID: base.revisionID)
                guard checked.report.revisionDigest == base.revisionDigest else { throw CreatorPersistence.Failure.staleValidation }
            }
            try cancelActiveIteration(projectID)
            var document = try readConversation(projectID)
            let turn = CreatorConversation.Turn(id: UUID(), token: UUID(), createdAt: CreatorPersistence.timestamp(),
                baseRevisionID: base?.revisionID, baseRevisionDigest: base?.revisionDigest,
                profileID: profile.id, configurationID: profile.configurationID, userMessage: message,
                maxRepairs: maxRepairs, requestBudget: min(1 + maxRepairs, profile.limits.requestBudget), tokenBudget: profile.limits.tokenBudget)
            document.turns.append(turn)
            try document.validate()
            let ticket = CreatorConversation.Ticket(id: turn.id, projectID: projectID, token: turn.token)
            let lease = try CreatorPersistence.Lease(iterationLeaseURL(ticket))
            try saveConversation(document)
            iterationLeases[turn.id] = lease
            return ticket
        }
    }
    func iteration(_ ticket: CreatorConversation.Ticket) throws -> CreatorConversation.Turn {
        try locked {
            guard let turn = try readConversation(ticket.projectID).turns.first(where: { $0.id == ticket.id }), turn.token == ticket.token
            else { throw CreatorPersistence.Failure.staleJob }
            return turn
        }
    }
    func activeIteration(_ ticket: CreatorConversation.Ticket) throws -> CreatorConversation.Turn {
        guard let turn = try readConversation(ticket.projectID).turns.last, turn.id == ticket.id, turn.token == ticket.token,
              !turn.state.terminal, iterationLeases[turn.id] != nil else { throw CreatorPersistence.Failure.staleJob }
        return turn
    }
    func iterationForJob(_ job: GenerationJob) throws -> CreatorConversation.Turn? {
        guard let id = job.iterationID else { return nil }
        guard let turn = try readConversation(job.projectID).turns.last, turn.id == id, !turn.state.terminal,
              turn.currentJobID == job.id, iterationLeases[id] != nil else { throw CreatorPersistence.Failure.staleJob }
        return turn
    }
    func updateIteration(_ ticket: CreatorConversation.Ticket, _ body: (inout CreatorConversation.Turn) throws -> Void) throws {
        var document = try readConversation(ticket.projectID)
        var turn = try activeIteration(ticket)
        try body(&turn)
        document.turns[document.turns.count - 1] = turn
        try saveConversation(document)
    }
    func moveIteration(_ ticket: CreatorConversation.Ticket, to state: CreatorConversation.State) throws {
        try locked {
            try Task.checkCancellation()
            try updateIteration(ticket) { turn in
                let next: [CreatorConversation.State: CreatorConversation.State] = [.generating: .runtime, .runtime: .sealing, .sealing: .publishing]
                guard next[turn.state] == state else { throw CreatorPersistence.Failure.staleJob }
                turn.state = state
            }
        }
    }
    func pendingRepair(_ ticket: CreatorConversation.Ticket, issue: CreatorRepairIssue, outputTokens: Int) throws -> Bool {
        try locked {
            try Task.checkCancellation()
            var allowed = false
            try updateIteration(ticket) { turn in
                guard [.generating, .runtime].contains(turn.state) else { throw CreatorPersistence.Failure.staleJob }
                turn.failure = issue
                if !turn.attempts.isEmpty { turn.attempts[turn.attempts.count - 1].issue = issue }
                allowed = issue.repairable && turn.requestCount > 0 && turn.requestCount < turn.requestBudget
                    && turn.repairCount < turn.maxRepairs && outputTokens > 0
                    && outputTokens <= turn.tokenBudget - turn.reservedOutputTokens
                if allowed { turn.state = .repairPending }
            }
            return allowed
        }
    }
    func resumeRepair(_ ticket: CreatorConversation.Ticket) throws {
        try locked {
            try Task.checkCancellation()
            try updateIteration(ticket) { turn in
                guard turn.state == .repairPending, turn.repairCount < turn.maxRepairs,
                      turn.requestCount < turn.requestBudget else { throw LLMFailure.budgetExhausted }
                turn.repairCount += 1; turn.state = .generating; turn.currentJobID = nil
            }
        }
    }
    func recordIterationDraft(_ ticket: CreatorConversation.Ticket, draft: CreatorRevision) throws {
        try locked {
            let report = try validReport(projectID: ticket.projectID, revisionID: draft.id)
            try updateIteration(ticket) { turn in
                guard turn.state == .generating, let metadata = draft.generation, metadata.iterationID == turn.id,
                      turn.attempts.last?.jobID == metadata.jobID, report.allowsPreview,
                      draft.parentID == turn.baseRevisionID else { throw CreatorPersistence.Failure.staleJob }
                turn.attempts[turn.attempts.count - 1].draftRevisionID = draft.id
                turn.attempts[turn.attempts.count - 1].usage = metadata.usage
            }
        }
    }
    func recordIterationUsage(_ ticket: CreatorConversation.Ticket, jobID: UUID, usage: LLMResponse.Usage) throws {
        try locked {
            try Task.checkCancellation()
            try updateIteration(ticket) { turn in
                guard turn.state == .generating, turn.currentJobID == jobID, turn.attempts.last?.jobID == jobID
                else { throw CreatorPersistence.Failure.staleJob }
                turn.attempts[turn.attempts.count - 1].usage = usage
            }
        }
    }
    func closeIteration(_ ticket: CreatorConversation.Ticket, state: CreatorConversation.State,
                        result: UUID? = nil, issue: CreatorRepairIssue? = nil, exhausted: Bool = false) throws {
        try locked { try closeIterationUnlocked(ticket, state: state, result: result, issue: issue, exhausted: exhausted) }
    }
    func closeIterationUnlocked(_ ticket: CreatorConversation.Ticket, state: CreatorConversation.State,
                                result: UUID? = nil, issue: CreatorRepairIssue? = nil, exhausted: Bool = false) throws {
        var document = try readConversation(ticket.projectID)
        guard let index = document.turns.firstIndex(where: { $0.id == ticket.id }), document.turns[index].token == ticket.token,
              state.terminal else { throw CreatorPersistence.Failure.staleJob }
        if document.turns[index].state.terminal { iterationLeases[ticket.id] = nil; return }
        defer { iterationLeases[ticket.id] = nil }
        if state == .completed {
            guard document.turns[index].state == .publishing, let result,
                  try validReport(projectID: ticket.projectID, revisionID: result).allowsPublication else { throw CreatorPersistence.Failure.staleValidation }
            let revision = try readRevision(projectID: ticket.projectID, revisionID: result).revision
            guard revision.generation?.iterationID == ticket.id,
                  revision.seal?.sourceRevisionID == document.turns[index].attempts.last?.draftRevisionID
            else { throw CreatorPersistence.Failure.staleValidation }
        } else if let jobID = try readProject(ticket.projectID).activeJobID {
            let job = try readJob(jobID)
            if job.iterationID == ticket.id { try cancelUnlocked(job.ticket) }
        }
        document.turns[index].state = state
        document.turns[index].failure = issue
        document.turns[index].budgetExhausted = exhausted
        document.turns[index].resultRevisionID = result
        if let issue, !document.turns[index].attempts.isEmpty {
            document.turns[index].attempts[document.turns[index].attempts.count - 1].issue = issue
        }
        try saveConversation(document)
        iterationLeases[ticket.id] = nil
    }
    func cancelActiveIteration(_ projectID: UUID) throws {
        if let turn = try readConversation(projectID).turns.last, !turn.state.terminal {
            try closeIterationUnlocked(.init(id: turn.id, projectID: projectID, token: turn.token), state: .cancelled, issue: .init(category: .cancelled))
        }
    }
    func reserveIterationAttempt(_ job: GenerationJob, profile: ProviderProfile, outputTokens: Int) throws {
        guard let turn = try iterationForJob(job) else { return }
        guard turn.state == .generating, turn.profileID == profile.id, turn.configurationID == profile.configurationID,
              job.attemptCount == 0, !turn.attempts.contains(where: { $0.jobID == job.id }),
              turn.requestCount < min(turn.requestBudget, profile.limits.requestBudget),
              outputTokens <= min(turn.tokenBudget, profile.limits.tokenBudget) - turn.reservedOutputTokens
        else { throw LLMFailure.budgetExhausted }
        let ticket = CreatorConversation.Ticket(id: turn.id, projectID: job.projectID, token: turn.token)
        // Reserve the whole-turn budget BEFORE the per-attempt job. A crash may overcount,
        // but can never refund an attempt or send a fourth request.
        try updateIteration(ticket) { $0.attempts.append(.init(jobID: job.id, reservedOutputTokens: outputTokens)) }
    }
}
