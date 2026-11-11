import Foundation

/// Versioned local preferences contain provider metadata, never keys or credential approvals.
struct CreatorSettings: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var profiles: [ProviderProfile] = []
    var selectedProfileID: UUID?

    func validate() throws {
        guard schemaVersion == 1 else { throw CreatorPersistence.Failure.unsupportedVersion }
        guard revision >= 0, profiles.count <= 32,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map(\.configurationID)).count == profiles.count,
              selectedProfileID.map({ id in profiles.contains { $0.id == id } }) ?? true
        else { throw CreatorPersistence.Failure.invalidRecord }
        for profile in profiles {
            try profile.validate()
            guard profile.configurationRevision > 0, profile.configurationRevision <= revision else { throw CreatorPersistence.Failure.invalidRecord }
        }
    }
}
