import Foundation

/// Headless launch recovery. No panel, credentials, model request or desktop action.
struct CreatorStartupRecovery: Sendable {
    let store: CreatorRevisionStore
    let publisher: CreatorPublisher
    let registry: CreatorRuntimeRegistry

    init(store: CreatorRevisionStore = CreatorRevisionStore(),
         publisher: CreatorPublisher = CreatorPublisher(),
         registry: CreatorRuntimeRegistry = CreatorRuntimeRegistry()) {
        self.store = store; self.publisher = publisher; self.registry = registry
    }

    func recover() async throws {
        guard CreatorPersistence.exists(store.root) || CreatorPersistence.exists(registry.url) else { return }
        try Task.checkCancellation()
        do {
            _ = try await CreatorRecoveryCoordinator.shared.recover(store: store, publisher: publisher)
        } catch let failure as CreatorPersistence.Failure { throw failure }
        catch let failure as CreatorTemplate.Failure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch { throw CreatorPersistence.Failure.invalidRecord }
    }
}
