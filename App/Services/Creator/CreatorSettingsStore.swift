import Foundation

/// Atomic metadata updates with optimistic revision checks and a lock shared by all store instances.
actor CreatorSettingsStore {
    enum Failure: Error, Equatable { case staleSettings, staleProfile, profileMissing, revisionLimit }
    nonisolated let url: URL
    private let beforeCommit: @Sendable () throws -> Void

    init(url: URL = ClientPaths.creatorSettingsURL, beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        self.url = url
        self.beforeCommit = beforeCommit
    }

    func settings() throws -> CreatorSettings {
        try Task.checkCancellation()
        return try read()
    }

    /// Check and start/register a request while holding the same file lock as profile edits.
    func withCurrentProfile<T: Sendable>(_ expected: ProviderProfile, perform: @Sendable (ProviderProfile) throws -> T) throws -> T {
        do {
            try Task.checkCancellation()
            try CreatorPersistence.directory(url.deletingLastPathComponent())
            let lock = try CreatorPersistence.Lease(url.appendingPathExtension("lock"))
            defer { withExtendedLifetime(lock) {} }
            let settings = try read()
            guard settings.profiles.first(where: { $0.id == expected.id }) == expected else { throw LLMFailure.staleProfile }
            return try perform(expected)
        } catch let failure as LLMFailure { throw failure }
        catch is CancellationError { throw LLMFailure.cancelled }
        catch CreatorPersistence.Failure.busy { throw LLMFailure.busy }
        catch { throw LLMFailure.staleProfile }
    }

    /// Fences stale configuration handles; S1.2 must independently check Keychain origin binding.
    func profile(id: UUID, configurationID: UUID) throws -> ProviderProfile {
        let settings = try settings()
        guard let profile = settings.profiles.first(where: { $0.id == id }) else { throw Failure.profileMissing }
        guard profile.configurationID == configurationID else { throw Failure.staleProfile }
        return profile
    }

    func saveProfile(_ profile: ProviderProfile, expectedRevision: Int) throws -> CreatorSettings {
        try profile.validate()
        return try update(expectedRevision: expectedRevision) { settings in
            var next = profile
            if let index = settings.profiles.firstIndex(where: { $0.id == profile.id }) {
                let previous = settings.profiles[index]
                guard profile.configurationRevision == previous.configurationRevision,
                      profile.configurationID == previous.configurationID else { throw Failure.staleProfile }
                if previous == profile { return }
                guard previous.configurationRevision < Int.max else { throw Failure.revisionLimit }
                next.configurationRevision = previous.configurationRevision + 1
                next.configurationID = UUID()
                settings.profiles[index] = next
            } else {
                guard profile.configurationRevision == 0 else { throw Failure.staleProfile }
                next.configurationRevision = 1
                next.configurationID = UUID()
                settings.profiles.append(next)
            }
        }
    }

    func selectProfile(_ id: UUID?, expectedRevision: Int) throws -> CreatorSettings {
        try update(expectedRevision: expectedRevision) { settings in
            guard id.map({ id in settings.profiles.contains { $0.id == id } }) ?? true else { throw Failure.profileMissing }
            settings.selectedProfileID = id
        }
    }

    func removeProfile(_ id: UUID, expectedRevision: Int) throws -> CreatorSettings {
        try update(expectedRevision: expectedRevision) { settings in
            guard settings.profiles.contains(where: { $0.id == id }) else { throw Failure.profileMissing }
            settings.profiles.removeAll { $0.id == id }
            if settings.selectedProfileID == id { settings.selectedProfileID = nil }
        }
    }

    private func read() throws -> CreatorSettings {
        guard CreatorPersistence.exists(url) else { return CreatorSettings() }
        let settings = try CreatorPersistence.read(CreatorSettings.self, at: url)
        try settings.validate()
        return settings
    }

    private func update(expectedRevision: Int, _ change: (inout CreatorSettings) throws -> Void) throws -> CreatorSettings {
        try Task.checkCancellation()
        try CreatorPersistence.directory(url.deletingLastPathComponent(), create: true)
        let lock = try CreatorPersistence.Lease(url.appendingPathExtension("lock"))
        defer { withExtendedLifetime(lock) {} }
        let previous = try read()
        guard previous.revision == expectedRevision else { throw Failure.staleSettings }
        var next = previous
        try change(&next)
        guard next != previous else { return previous }
        guard previous.revision < Int.max else { throw Failure.revisionLimit }
        next.revision += 1
        try next.validate()
        let data = try CreatorPersistence.record(next)
        guard data.count <= 256 * 1024 else { throw CreatorPersistence.Failure.tooLarge }
        try CreatorPersistence.atomicWrite(data, to: url) {
            try beforeCommit()
            try Task.checkCancellation()
            LLMRequestCoordinator.shared.profilesWillChange(at: url, to: next)
        }
        return next
    }
}
