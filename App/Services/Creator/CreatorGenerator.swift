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
        var modelID: String? = nil
        var mode: CreatorCreationMode = .template
        var engine: CreatorEngine? = nil
        var referenceSource: String? = nil
        var sendsThumbnail = false
        var iteration: CreatorConversation.Ticket? = nil
        var repair: CreatorRepairIssue? = nil
        var streamProgress: @Sendable (LLMStreamProgress) -> Void = { _ in }
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
        catch {
            if request.iteration != nil { throw CreatorRepairIssue.from(error) }
            throw CreatorGenerationFailure.sanitized(error)
        }
    }
    func cancel(projectID: UUID) { active[projectID]?.task.cancel() }

    func beginIteration(_ request: Request, maxRepairs: Int) async throws -> CreatorConversation.Ticket {
        try Task.checkCancellation()
        guard (0...2).contains(maxRepairs) else { throw CreatorGenerationFailure.invalidRequest }
        let profile = try await settings.profile(id: request.profileID, configurationID: request.configurationID)
        let base: CreatorPromptBuilder.Base?
        if let id = request.baseRevisionID { base = try await store.generationBase(projectID: request.projectID, revisionID: id) }
        else { base = nil }
        _ = try Self.input(engine: request.engine, referenceSource: request.referenceSource, mode: request.mode, prompt: request.prompt, base: base, maxOutputTokens: request.maxOutputTokens, repair: nil)
        guard request.maxOutputTokens <= profile.limits.generationTokenBudget else { throw CreatorGenerationFailure.invalidRequest }
        let message = try await provider.sanitizedContext([request.prompt], profile: profile)[0]
        guard !message.isEmpty else { throw CreatorGenerationFailure.invalidRequest }
        return try await store.beginIteration(projectID: request.projectID, base: base, profile: profile, message: message, maxRepairs: maxRepairs, mode: request.mode)
    }

    private static func input(engine: CreatorEngine?, referenceSource: String?, mode: CreatorCreationMode, prompt: String, base: CreatorPromptBuilder.Base?,
                              maxOutputTokens: Int, repair: CreatorRepairIssue?) throws -> LLMRequest {
        if mode == .code { return try CreatorEnginePrompt.build(engine: engine, prompt: prompt, base: base, referenceSource: referenceSource, maxOutputTokens: maxOutputTokens, repair: repair) }
        return try CreatorPromptBuilder.build(prompt: prompt, base: base, maxOutputTokens: maxOutputTokens, repair: repair)
    }

    private static func run(_ request: Request, store: CreatorRevisionStore, settings: CreatorSettingsStore,
                            provider: LLMProvider, checkpoint: @Sendable (Checkpoint) async throws -> Void) async throws -> CreatorRevision {
        try Task.checkCancellation()
        let profile = try await settings.profile(id: request.profileID, configurationID: request.configurationID)
        let base: CreatorPromptBuilder.Base?
        if let id = request.baseRevisionID { base = try await store.generationBase(projectID: request.projectID, revisionID: id) }
        else { base = nil }
        var prompt = request.prompt, contextBase = base
        let turn: CreatorConversation.Turn?
        if let iteration = request.iteration {
            let current = try await store.iteration(iteration)
            guard current.state == .generating, current.profileID == profile.id, current.configurationID == profile.configurationID,
                  current.baseRevisionID == request.baseRevisionID, (current.creationMode ?? .template) == request.mode,
                  (current.requestCount == 0 && request.repair == nil) || (current.requestCount > 0 && request.repair == current.failure)
            else { throw CreatorPersistence.Failure.staleJob }
            prompt = current.userMessage; turn = current
            if request.repair != nil, let candidate = current.attempts.reversed().compactMap(\.draftRevisionID).first {
                contextBase = try await store.generationBase(projectID: request.projectID, revisionID: candidate)
            }
            let texts = try await provider.sanitizedContext([prompt, contextBase?.title ?? "", contextBase?.summary ?? ""], profile: profile)
            prompt = texts[0]
            if let context = contextBase {
                contextBase = .init(revisionID: context.revisionID, revisionDigest: context.revisionDigest, templateID: context.templateID,
                    parameters: context.parameters, title: request.repair == nil ? texts[1] : "Wallpaper",
                    summary: request.repair == nil ? texts[2] : "Native validation candidate", source: context.source)
            }
        } else {
            guard request.repair == nil else { throw CreatorGenerationFailure.invalidRequest }
            turn = nil
        }
        var input = try Self.input(engine: request.engine, referenceSource: request.referenceSource, mode: request.mode, prompt: prompt, base: contextBase, maxOutputTokens: request.maxOutputTokens, repair: request.repair)
        input.modelID = request.modelID
        _ = try input.model(for: profile)
        if request.sendsThumbnail, let base = contextBase {
            guard (profile.visionModelIDs ?? []).contains(try input.model(for: profile)) else { throw CreatorGenerationFailure.invalidRequest }
            let snapshot = try await store.snapshot(projectID: request.projectID, revisionID: base.revisionID)
            if let media = snapshot.manifest?.media { input.thumbnailJPEG = snapshot.files[media.thumbnail.path] }
        }
        let engineReference = try CreatorEnginePrompt.reference(base: contextBase, source: request.referenceSource)
        if let source = contextBase?.source ?? request.referenceSource { try await provider.checkSourceContainsNoCredential(source, profile: profile) }
        guard input.maxOutputTokens <= profile.limits.generationTokenBudget else { throw CreatorGenerationFailure.invalidRequest }
        try Task.checkCancellation()
        let ticket = try await store.beginJob(projectID: request.projectID, baseRevisionID: request.baseRevisionID,
            requestBudget: turn == nil ? profile.limits.requestBudget : 1, tokenBudget: profile.limits.generationTokenBudget,
            expectedBaseDigest: base?.revisionDigest, iteration: request.iteration)
        do {
            try await checkpoint(.beforeRequest); try Task.checkCancellation()
            let completed = try await provider.generate(input, profileID: profile.id, configurationID: profile.configurationID,
                ticket: ticket, store: store, retrying: turn == nil, outputMode: turn?.effectiveJSONMode,
                streaming: turn?.usesNonStream != true, omitUsage: turn?.omitsUsage == true, adaptOutputLimit: turn?.adaptsOutputLimit == true, progress: request.streamProgress,
                validate: { text in
                    if request.mode == .code { _ = try CreatorEnginePrompt.output(text, engine: request.engine, reference: engineReference) }
                    else { _ = try CreatorOutputValidator.detailed(text) }
                },
                received: { response in
                    if let iteration = request.iteration { try await store.recordIterationUsage(iteration, jobID: ticket.id, usage: response.usage) }
                })
            try await checkpoint(.afterResponse); try Task.checkCancellation()
            let specification: CreatorTemplate.Specification, presentation: CreatorBundlePresentation
            let source: Data?
            if request.mode == .code {
                let output = try CreatorEnginePrompt.output(completed.response.text, engine: request.engine, reference: engineReference)
                try await provider.checkSourceContainsNoCredential(completed.response.text, profile: profile)
                // Legacy JSON may escape the key; check the decoded file bytes as well as the envelope.
                try await provider.checkSourceContainsNoCredential(String(decoding: output.html, as: UTF8.self), profile: profile)
                specification = try CreatorCodeOutput.specification(projectID: request.projectID, html: output.html)
                presentation = output.presentation; source = output.html
            } else {
                let output = try turn == nil ? CreatorOutputValidator.parse(completed.response.text) : CreatorOutputValidator.detailed(completed.response.text)
                let compiled = try CreatorTemplateCompiler.compile(output, projectID: request.projectID)
                specification = compiled.specification; presentation = compiled.presentation; source = nil
            }
            let texts = [presentation.title, presentation.summary]
            guard try await provider.sanitizedContext(texts, profile: profile) == texts else { throw CreatorRepairIssue.field("$", .text, policy: true) }
            try await checkpoint(.afterValidation); try Task.checkCancellation()
            try await settings.withCurrentProfile(profile) { _ in }
            let metadata = CreatorGenerationMetadata(schemaVersion: 1, jobID: ticket.id,
                configurationID: profile.configurationID, configurationRevision: profile.configurationRevision,
                protocolKind: profile.protocolKind, attemptCount: completed.attempts,
                reservedOutputTokens: completed.reservedOutputTokens, usage: completed.response.usage,
                elapsed: completed.elapsed, baseRevisionDigest: base?.revisionDigest, iterationID: request.iteration?.id, repairIndex: turn?.repairCount)
            let assets: [String: Data]?
            // Legacy parameter revisions need only their checked generation context, not
            // a modern preview report. Load asset bytes only for a media-bearing core.
            if let base = contextBase, engineReference?.metadata.media != nil {
                assets = try await store.snapshot(projectID: request.projectID, revisionID: base.revisionID).assets
            } else { assets = nil }
            _ = try await store.stage(specification, for: ticket, summary: CreatorPromptBuilder.promptSummary(prompt),
                presentation: presentation, generation: metadata, source: source, assets: assets, providerID: profile.id.uuidString.lowercased(), modelID: try input.model(for: profile))
            try await checkpoint(.beforeCommit); try Task.checkCancellation()
            try await settings.withCurrentProfile(profile) { _ in }
            let draft = try await store.commit(ticket, validatingStructure: true)
            if let iteration = request.iteration { try await store.recordIterationDraft(iteration, draft: draft) }
            return draft
        } catch {
            let failure = CreatorGenerationFailure.sanitized(error)
            do { try await store.cancel(ticket) }
            catch { throw CreatorGenerationFailure.storage }
            if request.iteration != nil, (error as? LLMFailure) == .jsonModeUnsupported,
               profile.protocolKind == .openaiCompatible, (profile.capabilities.jsonMode ?? .automatic) == .automatic {
                throw CreatorRepairIssue(category: .jsonModeUnsupported)
            }
            if request.iteration != nil { throw CreatorRepairIssue.from(error) }
            throw failure
        }
    }
}
