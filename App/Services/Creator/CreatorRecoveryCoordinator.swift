import Foundation

/// Coalesces panel/headless recovery of one store. A caller's cancellation cannot
/// abandon shared rollback; live publication and generation leases still fence it.
actor CreatorRecoveryCoordinator {
    static let shared = CreatorRecoveryCoordinator()
    private var running: [URL: Task<CreatorRevisionStore.Recovery, Error>] = [:]

    func recover(store: CreatorRevisionStore, publisher: CreatorPublisher) async throws -> CreatorRevisionStore.Recovery {
        let key = store.root.standardizedFileURL
        if let task = running[key] { return try await task.value }
        let task = Task {
            try await publisher.recover(store: store)
            return try await store.recover()
        }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}
