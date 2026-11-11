import Foundation

/// Panel-facing domain operations. No view loads files, touches credentials or assembles requests.
actor CreatorWorkspace {
    struct Detail: Sendable {
        let project: CreatorProject
        let revisions: [CreatorRevision]
        let reports: [UUID: ValidationReport]
        let conversation: CreatorConversation
        let specification: CreatorTemplate.Specification?
        let installedRevisionID: UUID?
        var source: String? = nil
        var parameterSchema: CreatorParameterSchema? = nil
    }
    let store: CreatorRevisionStore
    let settings: CreatorSettingsStore
    let credentials: ProviderCredentialStore
    let provider: LLMProvider
    let publisher: CreatorPublisher
    let registry: CreatorRuntimeRegistry
    let orchestrator: CreatorOrchestrator
    private let library: URL
    private let capture: CreatorOrchestrator.Capture
    private let beforeWrite: @Sendable () throws -> Void

    init(store: CreatorRevisionStore = .init(), settings: CreatorSettingsStore = .init(),
         credentials: ProviderCredentialStore = .init(), provider: LLMProvider? = nil,
         publisher: CreatorPublisher = .init(), registry: CreatorRuntimeRegistry = .init(),
         library: URL = ClientPaths.libraryURL,
         capture: @escaping CreatorOrchestrator.Capture = { project, revision, store in
             try await CreatorPosterService().capture(projectID: project, revisionID: revision, store: store)
         }, beforeWrite: @escaping @Sendable () throws -> Void = { try CreatorStorageBoundary.beginCreatorWrite() }) {
        let provider = provider ?? LLMProvider(settings: settings, credentials: credentials)
        self.store = store; self.settings = settings; self.credentials = credentials
        self.provider = provider; self.publisher = publisher; self.registry = registry
        self.library = library
        self.capture = capture; self.beforeWrite = beforeWrite
        orchestrator = CreatorOrchestrator(store: store,
            generator: CreatorGenerator(store: store, settings: settings, provider: provider), publisher: publisher, capture: capture)
    }
    func recover() async throws -> CreatorRevisionStore.Recovery { try await orchestrator.recover() }
    func projects() async throws -> [CreatorRevisionStore.WorkspaceProject] { try await store.workspaceProjects() }
    func configuration() async throws -> CreatorSettings { try await settings.settings() }
    func detail(_ id: UUID) async throws -> Detail {
        let project = try await store.project(id)
        var revisions: [CreatorRevision] = [], reports: [UUID: ValidationReport] = [:]
        for revisionID in project.revisionIDs.reversed() {
            try Task.checkCancellation()
            revisions.append(try await store.revision(projectID: id, revisionID: revisionID))
            // A failed or tampered report is shown as unavailable; it never enables preview/save.
            if let report = try? await store.report(projectID: id, revisionID: revisionID) { reports[revisionID] = report }
        }
        let specification: CreatorTemplate.Specification?
        var source: String?
        var parameterSchema: CreatorParameterSchema?
        if let revision = project.selectedRevisionID, reports[revision] != nil {
            let snapshot = try await store.snapshot(projectID: id, revisionID: revision)
            specification = snapshot.specification
            parameterSchema = try snapshot.files["index.html"].flatMap { try CreatorParameterSchema.read(String(decoding: $0, as: UTF8.self)) }
            source = snapshot.files["index.html"].map { LLMStreamText.sanitize(String(decoding: $0, as: UTF8.self)) }
        } else { specification = nil }
        let installed = try await registry.bindings().values.first { $0.projectID == id }
        return Detail(project: project, revisions: revisions, reports: reports,
                      conversation: try await store.conversation(projectID: id), specification: specification, installedRevisionID: installed?.revisionID, source: source, parameterSchema: parameterSchema)
    }
    func create(title: String) async throws -> UUID {
        try beforeWrite(); return try await store.createProject(title: title).id
    }
    func rename(_ id: UUID, title: String) async throws {
        try beforeWrite(); try await store.setDisplayName(id, title: title)
    }
    func delete(_ id: UUID) async throws { try beforeWrite(); try await store.deleteDraft(id) }
    func select(project: UUID, revision: UUID) async throws {
        try beforeWrite(); _ = try await orchestrator.selectRevision(projectID: project, revisionID: revision)
    }
    func generate(_ request: CreatorOrchestrator.Request) async throws -> CreatorOrchestrator.Prepared {
        try beforeWrite()
        if let project = request.projectID {
            let profile = try await settings.profile(id: request.profileID, configurationID: request.configurationID)
            let safe = try await provider.sanitizedContext([request.prompt], profile: profile)[0]
            try await store.nameFirstPrompt(project, sanitizedPrompt: safe)
        }
        return try await orchestrator.createForPreview(request)
    }
    func installedWallpaper(project: UUID, revision: UUID) async throws -> String {
        let publication = try await store.publication(projectID: project, revisionID: revision)
        let binding = publication.binding
        guard try await registry.bindings()[binding.wallpaperID] == binding else { throw CreatorPersistence.Failure.staleValidation }
        _ = try CreatorRuntimeRegistry.readForPlayback(library.appendingPathComponent(binding.wallpaperID),
            expectedDigest: binding.bundleDigest, registryURL: registry.url, publicationRoot: publisher.root)
        return binding.wallpaperID
    }
    func publish(project: UUID, revision: UUID) async throws -> URL {
        try beforeWrite(); try Task.checkCancellation()
        let installed = try await publisher.publish(projectID: project, revisionID: revision, store: store)
        let publication = try await store.publication(projectID: project, revisionID: revision)
        try await store.recordPublished(publication.binding)
        return installed
    }
    /// Parameters form a new immutable revision and receive real runtime evidence, without an LLM.
    func edit(project: UUID, revision: UUID, parameters: [String: CreatorTemplateCatalog.Value]) async throws -> CreatorRevision {
        try beforeWrite()
        let snapshot = try await store.snapshot(projectID: project, revisionID: revision)
        var spec = snapshot.specification
        if spec.kind == .code, let bytes = snapshot.files["index.html"], let schema = try CreatorParameterSchema.read(String(decoding: bytes, as: UTF8.self)) {
            let html = Data(try schema.replacing(in: String(decoding: bytes, as: UTF8.self), with: parameters).utf8)
            spec = try CreatorCodeOutput.specification(projectID: project, html: html)
            return try await rebuild(spec, base: revision, source: html)
        }
        guard let templateID = spec.templateID else { throw CreatorGenerationFailure.policyViolation }
        try CreatorTemplateCatalog.definition(templateID).validate(parameters)
        spec.parameters = parameters
        spec.rendererRevision = 3
        return try await rebuild(spec, base: revision)
    }
    func duplicate(_ id: UUID, title: String) async throws -> UUID {
        try beforeWrite()
        let project = try await store.project(id)
        let next = try await store.createProject(title: title)
        do {
            if let revision = project.selectedRevisionID {
                let original = try await store.snapshot(projectID: id, revisionID: revision)
                var spec = original.specification
                spec.projectID = next.id
                _ = try await rebuild(spec, base: nil, source: spec.kind == .code ? original.files["index.html"] : nil)
            }
            return next.id
        } catch {
            // Cleanup must run even when the copying task was cancelled.
            let store = store
            _ = await Task.detached { try? await store.deleteDraft(next.id) }.value
            throw error
        }
    }
    private func rebuild(_ specification: CreatorTemplate.Specification, base: UUID?, source: Data? = nil) async throws -> CreatorRevision {
        let ticket = try await store.beginJob(projectID: specification.projectID, baseRevisionID: base)
        do {
            _ = try await store.stage(specification, for: ticket, source: source)
            let draft = try await store.commit(ticket, validatingStructure: true, selecting: false)
            let evidence = try await capture(specification.projectID, draft.id, store)
            try Task.checkCancellation()
            return try await store.seal(evidence)
        } catch {
            let store = store
            _ = await Task.detached { try? await store.cancel(ticket) }.value
            if let base { _ = await Task.detached { try? await store.select(projectID: specification.projectID, revisionID: base) }.value }
            throw error
        }
    }
    func models(profile: ProviderProfile, key: String) async throws -> [String] {
        try await LLMModelCatalog().fetch(profile: profile, key: key)
    }
    func saveProfile(_ profile: ProviderProfile, key: String, expectedRevision: Int) async throws -> CreatorSettings {
        try beforeWrite()
        var draft = profile
        if !key.isEmpty && draft.allowsEmptyKey { draft.usesCredential = true }
        else if draft.allowsEmptyKey { draft.usesCredential = false }
        var result = try await settings.saveProfile(draft, expectedRevision: expectedRevision)
        guard let saved = result.profiles.first(where: { $0.id == profile.id }) else { throw LLMFailure.staleProfile }
        // Blank input means no credential action. Old bindings cannot authorize a new generation.
        if !key.isEmpty || saved.allowsEmptyKey { try await credentials.bind(key, to: saved, settings: settings) }
        if result.selectedProfileID == nil { result = try await settings.selectProfile(saved.id, expectedRevision: result.revision) }
        return result
    }
    func selectProfile(_ id: UUID, expectedRevision: Int) async throws -> CreatorSettings {
        try beforeWrite(); return try await settings.selectProfile(id, expectedRevision: expectedRevision)
    }
    func removeProfile(_ id: UUID, expectedRevision: Int) async throws -> CreatorSettings {
        try beforeWrite()
        let document = try await settings.settings()
        guard document.revision == expectedRevision, let profile = document.profiles.first(where: { $0.id == id }) else { throw LLMFailure.staleProfile }
        try await credentials.remove(for: profile, settings: settings)
        return try await settings.removeProfile(id, expectedRevision: expectedRevision)
    }
    struct ConnectionResult: Equatable, Sendable {
        let profileID: UUID
        let configurationID: UUID
        let model: String
        let protocolKind: ProviderProfile.ProtocolKind
        let mode: ProviderProfile.Capabilities.JSONMode
        let elapsed: TimeInterval
        let attempts: Int
        let usage: LLMResponse.Usage
    }
    /// Confirmed, budgeted protocol negotiation. No response text or key is persisted.
    func testConnection(_ profile: ProviderProfile) async throws -> ConnectionResult {
        try beforeWrite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-connection-" + UUID().uuidString)
        let temporary = CreatorRevisionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await temporary.createProject(title: "Connection")
        let ticket = try await temporary.beginJob(projectID: project.id, requestBudget: profile.limits.requestBudget, tokenBudget: profile.limits.generationTokenBudget)
        let completion = try await provider.generate(LLMRequest(system: "Connection check.", messages: [.init(role: .user, content: "Return {\"ok\":true}.")],
            maxOutputTokens: profile.limits.outputTokensPerRequest, structuredOutput: .init(name: "connection_check",
                schema: Data(#"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#.utf8))), profileID: profile.id, configurationID: profile.configurationID,
            ticket: ticket, store: temporary, validate: { text in
                guard (try? CreatorJSON.parse(text)) == .object(["ok": .bool(true)]) else { throw LLMFailure.protocolViolation }
            })
        try await temporary.cancel(ticket)
        return .init(profileID: profile.id, configurationID: profile.configurationID, model: profile.model,
            protocolKind: profile.protocolKind, mode: completion.effectiveJSONMode, elapsed: completion.elapsed,
            attempts: completion.attempts, usage: completion.response.usage)
    }
}
