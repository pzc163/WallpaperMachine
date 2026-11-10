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
    }
    struct Outcome: Sendable {
        let projectID: UUID
        let draft: CreatorRevision
        let sealed: CreatorRevision
        let installedDirectory: URL
    }
    enum Stage: String, Sendable { case generating, runtime, sealing, publishing, completed }
    struct Failure: Error, Sendable, CustomStringConvertible {
        let stage: Stage
        let code: String
        var description: String { "\(stage.rawValue):\(code)" }
    }
    typealias Capture = @Sendable (UUID, UUID, CreatorRevisionStore) async throws -> CreatorRuntimeCapture
    private let store: CreatorRevisionStore
    private let generator: CreatorGenerator
    private let publisher: CreatorPublisher
    private let capture: Capture
    private let checkpoint: @Sendable (Stage) async throws -> Void
    private var active: [UUID: (id: UUID, task: Task<Outcome, Error>)] = [:]

    init(store: CreatorRevisionStore, generator: CreatorGenerator, publisher: CreatorPublisher,
         capture: @escaping Capture = { project, revision, store in
             try await nativeCapture(project, revision, store)
         }, checkpoint: @escaping @Sendable (Stage) async throws -> Void = { _ in }) {
        self.store = store; self.generator = generator; self.publisher = publisher
        self.capture = capture; self.checkpoint = checkpoint
    }

    func createAndSave(_ request: Request) async throws -> Outcome {
        try Task.checkCancellation()
        guard request.projectID != nil || request.baseRevisionID == nil else { throw CreatorGenerationFailure.invalidRequest }
        guard active.count < 4 || request.projectID.map({ active[$0] != nil }) == true else { throw CreatorGenerationFailure.busy }
        let projectID: UUID
        if let id = request.projectID { projectID = id }
        else { projectID = try await store.createProject(title: request.title).id }
        active[projectID]?.task.cancel()
        let id = UUID(), store = store, generator = generator, publisher = publisher, capture = capture, checkpoint = checkpoint
        let task = Task {
            var stage = Stage.generating
            do {
                try await checkpoint(stage); try Task.checkCancellation()
                let draft = try await generator.generate(.init(projectID: projectID, baseRevisionID: request.baseRevisionID,
                    profileID: request.profileID, configurationID: request.configurationID, prompt: request.prompt,
                    maxOutputTokens: request.maxOutputTokens))
                stage = .runtime
                try await checkpoint(stage); try Task.checkCancellation()
                let evidence = try await capture(projectID, draft.id, store)
                stage = .sealing
                try await checkpoint(stage); try Task.checkCancellation()
                let sealed = try await store.seal(evidence)
                stage = .publishing
                try await checkpoint(stage); try Task.checkCancellation()
                let installed = try await publisher.publish(projectID: projectID, revisionID: sealed.id, store: store) { _ in
                    let project = try await store.project(projectID)
                    guard project.latestRevisionID == sealed.id, project.activeJobID == nil else { throw CreatorPersistence.Failure.staleJob }
                }
                let publication = try await store.publication(projectID: projectID, revisionID: sealed.id)
                try await store.recordPublished(publication.binding)
                return Outcome(projectID: projectID, draft: draft, sealed: sealed, installedDirectory: installed)
            } catch {
                let code: String
                if error is CancellationError || Task.isCancelled { code = "cancelled" }
                else if let failure = error as? CreatorRuntimeFailure { code = failure.rawValue }
                else { code = CreatorGenerationFailure.sanitized(error).description }
                throw Failure(stage: stage, code: code)
            }
        }
        active[projectID] = (id, task)
        defer { if active[projectID]?.id == id { active[projectID] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancel(projectID: UUID) { active[projectID]?.task.cancel() }

    func recover() async throws -> CreatorRevisionStore.Recovery {
        guard active.isEmpty else { throw CreatorGenerationFailure.busy }
        try await publisher.recover(store: store)
        return try await store.recover()
    }

    @MainActor private static func nativeCapture(_ project: UUID, _ revision: UUID, _ store: CreatorRevisionStore) async throws -> CreatorRuntimeCapture {
        try await CreatorPosterService().capture(projectID: project, revisionID: revision, store: store)
    }
}
