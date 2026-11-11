import Foundation

/// The local creation/save workflow; applying a wallpaper is deliberately a separate operation.
actor CreatorOrchestrator {
    struct Request: Sendable {
        var projectID: UUID? = nil
        var title = "Creator"
        var baseRevisionID: UUID? = nil
        let profileID: UUID
        let configurationID: UUID
        let prompt: String
        var maxOutputTokens = 2048
        var modelID: String? = nil
        var maxRepairs = 0
        var mode: CreatorCreationMode = .template
        var engine: CreatorEngine? = nil
        var referenceSource: String? = nil
        var sendsThumbnail = false
        var streamProgress: @Sendable (LLMStreamProgress) -> Void = { _ in }
        var progress: @Sendable (Stage, Int, Int) async -> Void = { _, _, _ in }
    }
    struct Outcome: Sendable {
        let projectID: UUID
        let draft: CreatorRevision
        let sealed: CreatorRevision
        let installedDirectory: URL
        let iterationID: UUID
    }
    struct Prepared: Sendable {
        let projectID: UUID
        let draft: CreatorRevision
        let sealed: CreatorRevision
        let iterationID: UUID
        var installedDirectory: URL? = nil
    }
    enum Stage: String, Sendable { case generating, repairPending, runtime, sealing, publishing, completed }
    struct Failure: Error, Sendable, CustomStringConvertible {
        let stage: Stage
        let code: String
        var iterationID: UUID? = nil
        var issue: CreatorRepairIssue? = nil
        var requestCount = 0
        var budgetExhausted = false
        var description: String { "\(stage.rawValue):\(code)" }
    }
    typealias Capture = @Sendable (UUID, UUID, CreatorRevisionStore) async throws -> CreatorRuntimeCapture
    private let store: CreatorRevisionStore
    private let generator: CreatorGenerator
    private let publisher: CreatorPublisher
    private let capture: Capture
    private let checkpoint: @Sendable (Stage) async throws -> Void
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private var active: [UUID: (id: UUID, task: Task<Prepared, Error>)] = [:]

    init(store: CreatorRevisionStore, generator: CreatorGenerator, publisher: CreatorPublisher,
         capture: @escaping Capture = { project, revision, store in
             try await nativeCapture(project, revision, store)
         }, checkpoint: @escaping @Sendable (Stage) async throws -> Void = { _ in },
         wait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store; self.generator = generator; self.publisher = publisher
        self.capture = capture; self.checkpoint = checkpoint; self.wait = wait
    }

    func createAndSave(_ request: Request) async throws -> Outcome {
        let result = try await perform(request, publish: true)
        guard let directory = result.installedDirectory else { throw CreatorPersistence.Failure.incompleteBundle }
        return Outcome(projectID: result.projectID, draft: result.draft, sealed: result.sealed,
                       installedDirectory: directory, iterationID: result.iterationID)
    }

    /// The panel stops here; publication and desktop application require separate user actions.
    func createForPreview(_ request: Request) async throws -> Prepared {
        try await perform(request, publish: false)
    }

    private func perform(_ request: Request, publish: Bool) async throws -> Prepared {
        try Task.checkCancellation()
        guard (0...2).contains(request.maxRepairs) else { throw CreatorGenerationFailure.invalidRequest }
        guard request.projectID != nil || request.baseRevisionID == nil else { throw CreatorGenerationFailure.invalidRequest }
        guard active.count < 4 || request.projectID.map({ active[$0] != nil }) == true else { throw CreatorGenerationFailure.busy }
        let projectID: UUID
        if let id = request.projectID { projectID = id }
        else { projectID = try await store.createProject(title: request.title).id }
        active[projectID]?.task.cancel()
        let id = UUID(), store = store, generator = generator, publisher = publisher, capture = capture, checkpoint = checkpoint, wait = wait
        let task = Task {
            var stage = Stage.generating
            var ticket: CreatorConversation.Ticket?
            do {
                try await checkpoint(stage); try Task.checkCancellation()
                var input = CreatorGenerator.Request(projectID: projectID, baseRevisionID: request.baseRevisionID,
                    profileID: request.profileID, configurationID: request.configurationID, prompt: request.prompt,
                    maxOutputTokens: request.maxOutputTokens, modelID: request.modelID, mode: request.mode, engine: request.engine, referenceSource: request.referenceSource, sendsThumbnail: request.sendsThumbnail, streamProgress: request.streamProgress)
                let iteration = try await generator.beginIteration(input, maxRepairs: request.maxRepairs)
                ticket = iteration; input.iteration = iteration
                while true {
                    do {
                        stage = .generating
                        if input.repair != nil { try await checkpoint(stage) }
                        try Task.checkCancellation()
                        let turn = try await store.iteration(iteration)
                        await request.progress(stage, turn.requestCount + 1, turn.requestBudget)
                        let draft = try await generator.generate(input)
                        stage = .runtime
                        await request.progress(stage, turn.requestCount + 1, turn.requestBudget)
                        try await store.moveIteration(iteration, to: .runtime)
                        try await checkpoint(stage); try Task.checkCancellation()
                        let evidence = try await capture(projectID, draft.id, store)
                        stage = .sealing
                        await request.progress(stage, turn.requestCount + 1, turn.requestBudget)
                        try await store.moveIteration(iteration, to: .sealing)
                        try await checkpoint(stage); try Task.checkCancellation()
                        let sealed = try await store.seal(evidence, iteration: iteration)
                        if !publish {
                            try await store.closeIteration(iteration, state: .completed, result: sealed.id)
                            await request.progress(.completed, turn.requestCount + 1, turn.requestBudget)
                            return Prepared(projectID: projectID, draft: draft, sealed: sealed, iterationID: iteration.id)
                        }
                        stage = .publishing
                        try await store.moveIteration(iteration, to: .publishing)
                        try await checkpoint(stage); try Task.checkCancellation()
                        let installed = try await publisher.publish(projectID: projectID, revisionID: sealed.id, store: store) { _ in
                            let project = try await store.project(projectID), current = try await store.iteration(iteration)
                            guard project.latestRevisionID == sealed.id, project.activeJobID == nil, current.state == .publishing
                            else { throw CreatorPersistence.Failure.staleJob }
                        }
                        let publication = try await store.publication(projectID: projectID, revisionID: sealed.id)
                        try await store.recordPublished(publication.binding)
                        try await store.closeIteration(iteration, state: .completed, result: sealed.id)
                        return Prepared(projectID: projectID, draft: draft, sealed: sealed, iterationID: iteration.id, installedDirectory: installed)
                    } catch {
                        try Task.checkCancellation()
                        let issue = CreatorRepairIssue.from(error)
                        guard [.generating, .runtime].contains(stage), issue.repairable,
                              try await store.pendingRepair(iteration, issue: issue, outputTokens: request.maxOutputTokens)
                        else { throw error }
                        stage = .repairPending
                        let pending = try await store.iteration(iteration)
                        await request.progress(stage, pending.requestCount, pending.requestBudget)
                        try await checkpoint(stage); try Task.checkCancellation()
                        if issue.category == .rateLimited { try await wait(issue.retryAfter ?? 1) }
                        if issue.category == .server { try await wait(0.5) }
                        try Task.checkCancellation()
                        try await store.resumeRepair(iteration)
                        input.repair = issue
                    }
                }
            } catch {
                let issue = Task.isCancelled ? CreatorRepairIssue(category: .cancelled) : CreatorRepairIssue.from(error)
                var count = 0, exhausted = false
                if let ticket {
                    do {
                        let turn = try await store.iteration(ticket)
                        count = turn.requestCount
                        exhausted = issue.repairable && count > 0 && (count >= turn.requestBudget || turn.repairCount >= turn.maxRepairs
                            || request.maxOutputTokens > turn.tokenBudget - turn.reservedOutputTokens)
                        try await store.closeIteration(ticket, state: issue.category == .cancelled ? .cancelled : .failed,
                            issue: issue, exhausted: exhausted)
                    } catch { throw Failure(stage: stage, code: "storage", iterationID: ticket.id, issue: .init(category: .storage), requestCount: count) }
                }
                throw Failure(stage: stage, code: issue.description, iterationID: ticket?.id, issue: issue, requestCount: count, budgetExhausted: exhausted)
            }
        }
        active[projectID] = (id, task)
        defer { if active[projectID]?.id == id { active[projectID] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancel(projectID: UUID) { active[projectID]?.task.cancel() }

    func selectRevision(projectID: UUID, revisionID: UUID) async throws -> CreatorRevision {
        // Validate before cancelling so an invalid selection cannot discard useful work.
        _ = try await store.report(projectID: projectID, revisionID: revisionID)
        active[projectID]?.task.cancel()
        try await store.select(projectID: projectID, revisionID: revisionID)
        return try await store.revision(projectID: projectID, revisionID: revisionID)
    }

    func recover() async throws -> CreatorRevisionStore.Recovery {
        guard active.isEmpty else { throw CreatorGenerationFailure.busy }
        return try await CreatorRecoveryCoordinator.shared.recover(store: store, publisher: publisher)
    }

    @MainActor private static func nativeCapture(_ project: UUID, _ revision: UUID, _ store: CreatorRevisionStore) async throws -> CreatorRuntimeCapture {
        try await CreatorPosterService().capture(projectID: project, revisionID: revision, store: store)
    }
}
