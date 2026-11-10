import Foundation

/// The local generation transaction ends with immutable bytes and structure-only evidence.
actor CreatorGenerator {
    struct Request: Sendable {
        let projectID: UUID
        var baseRevisionID: UUID? = nil
        let profileID: UUID
        let configurationID: UUID
        let prompt: String
        var maxOutputTokens = 2048
    }
    enum Checkpoint: Equatable, Sendable { case beforeRequest, afterResponse, afterValidation, beforeCommit }
    private let store: CreatorRevisionStore
    private let settings: CreatorSettingsStore
    private let provider: LLMProvider
    private let checkpoint: @Sendable (Checkpoint) async throws -> Void
    private var active: [UUID: (id: UUID, task: Task<CreatorRevision, Error>)] = [:]

    init(store: CreatorRevisionStore, settings: CreatorSettingsStore, provider: LLMProvider,
         checkpoint: @escaping @Sendable (Checkpoint) async throws -> Void = { _ in }) {
        self.store = store; self.settings = settings; self.provider = provider; self.checkpoint = checkpoint
    }
    func generate(_ request: Request) async throws -> CreatorRevision {
        guard active[request.projectID] != nil || active.count < 4 else { throw CreatorGenerationFailure.busy }
        active[request.projectID]?.task.cancel()
        let id = UUID(), store = store, settings = settings, provider = provider, checkpoint = checkpoint
        let operation = Task { try await Self.run(request, store: store, settings: settings, provider: provider, checkpoint: checkpoint) }
        active[request.projectID] = (id, operation)
        defer { if active[request.projectID]?.id == id { active[request.projectID] = nil } }
        do { return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() } }
        catch { throw CreatorGenerationFailure.sanitized(error) }
    }
    func cancel(projectID: UUID) { active[projectID]?.task.cancel() }

    private static func run(_ request: Request, store: CreatorRevisionStore, settings: CreatorSettingsStore,
                            provider: LLMProvider, checkpoint: @Sendable (Checkpoint) async throws -> Void) async throws -> CreatorRevision {
        try Task.checkCancellation()
        let profile = try await settings.profile(id: request.profileID, configurationID: request.configurationID)
        let base: CreatorPromptBuilder.Base?
        if let id = request.baseRevisionID { base = try await store.generationBase(projectID: request.projectID, revisionID: id) }
        else { base = nil }
        let input = try CreatorPromptBuilder.build(prompt: request.prompt, base: base, maxOutputTokens: request.maxOutputTokens)
        guard input.maxOutputTokens <= profile.limits.tokenBudget else { throw CreatorGenerationFailure.invalidRequest }
        try Task.checkCancellation()
        let ticket = try await store.beginJob(projectID: request.projectID, baseRevisionID: request.baseRevisionID,
            requestBudget: profile.limits.requestBudget, tokenBudget: profile.limits.tokenBudget, expectedBaseDigest: base?.revisionDigest)
        do {
            try await checkpoint(.beforeRequest); try Task.checkCancellation()
            let completed = try await provider.generate(input, profileID: profile.id, configurationID: profile.configurationID, ticket: ticket, store: store)
            try await checkpoint(.afterResponse); try Task.checkCancellation()
            let output = try CreatorOutputValidator.parse(completed.response.text)
            try await checkpoint(.afterValidation); try Task.checkCancellation()
            let compiled = try CreatorTemplateCompiler.compile(output, projectID: request.projectID)
            try await settings.withCurrentProfile(profile) { _ in }
            let metadata = CreatorGenerationMetadata(schemaVersion: 1, jobID: ticket.id,
                configurationID: profile.configurationID, configurationRevision: profile.configurationRevision,
                protocolKind: profile.protocolKind, attemptCount: completed.attempts,
                reservedOutputTokens: completed.reservedOutputTokens, usage: completed.response.usage,
                elapsed: completed.elapsed, baseRevisionDigest: base?.revisionDigest)
            _ = try await store.stage(compiled.specification, for: ticket, summary: CreatorPromptBuilder.promptSummary(request.prompt),
                presentation: compiled.presentation, generation: metadata, providerID: profile.id.uuidString.lowercased(), modelID: profile.model)
            try await checkpoint(.beforeCommit); try Task.checkCancellation()
            try await settings.withCurrentProfile(profile) { _ in }
            return try await store.commit(ticket, validatingStructure: true)
        } catch {
            let failure = CreatorGenerationFailure.sanitized(error)
            do { try await store.cancel(ticket) }
            catch { throw CreatorGenerationFailure.storage }
            throw failure
        }
    }
}
