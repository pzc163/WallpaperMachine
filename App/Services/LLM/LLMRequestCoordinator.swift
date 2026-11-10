import Foundation

/// Synchronous invalidation bridges atomic store commits to cancellation of active native tasks.
final class LLMRequestCoordinator: @unchecked Sendable {
    static let shared = LLMRequestCoordinator()
    private struct Entry {
        let settingsPath: String
        let profile: ProviderProfile
        let jobPath: String
        let ticket: GenerationJob.Ticket
        let cancel: @Sendable (LLMFailure) -> Void
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func register(settingsURL: URL, profile: ProviderProfile, jobURL: URL, ticket: GenerationJob.Ticket,
                  cancel: @escaping @Sendable (LLMFailure) -> Void) throws -> UUID {
        let entry = Entry(settingsPath: path(settingsURL), profile: profile, jobPath: path(jobURL), ticket: ticket, cancel: cancel)
        return try lock.withLock {
            guard entries.count < 32, !entries.values.contains(where: { $0.jobPath == entry.jobPath }) else { throw LLMFailure.busy }
            let id = UUID(); entries[id] = entry; return id
        }
    }
    func remove(_ id: UUID) { _ = lock.withLock { entries.removeValue(forKey: id) } }
    func profilesWillChange(at url: URL, to settings: CreatorSettings) {
        let location = path(url)
        let callbacks = lock.withLock {
            entries.values.filter { entry in
                entry.settingsPath == location && settings.profiles.first(where: { $0.id == entry.profile.id }) != entry.profile
            }.map(\.cancel)
        }
        callbacks.forEach { $0(.staleProfile) }
    }
    func credentialChanged(at url: URL, profileID: UUID) {
        let location = path(url)
        let callbacks = lock.withLock { entries.values.filter { $0.settingsPath == location && $0.profile.id == profileID }.map(\.cancel) }
        callbacks.forEach { $0(.credentialsUnavailable) }
    }
    func jobCancelled(at url: URL, ticket: GenerationJob.Ticket) {
        let location = path(url)
        let callbacks = lock.withLock { entries.values.filter { $0.jobPath == location && $0.ticket == ticket }.map(\.cancel) }
        callbacks.forEach { $0(.cancelled) }
    }
    private func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
