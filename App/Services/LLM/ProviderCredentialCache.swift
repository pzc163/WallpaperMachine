import Foundation

/// In-memory only; store commits synchronously erase stale bindings before cancelling requests.
final class ProviderCredentialCache: @unchecked Sendable {
    private struct Entry { let profile: ProviderProfile; let settingsURL: URL; let key: String }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var observer: UUID?
    init() {
        observer = LLMRequestCoordinator.shared.observeCredentials { [weak self] url, settings, id in
            guard let self else { return }
            self.lock.withLock {
                self.entries = self.entries.filter { _, entry in
                    guard entry.settingsURL == url else { return true }
                    if let id { return entry.profile.id != id }
                    return settings?.profiles.contains(entry.profile) == true
                }
            }
        }
    }
    deinit { if let observer { LLMRequestCoordinator.shared.removeCredentialObserver(observer) } }
    func key(profile: ProviderProfile, settingsURL: URL) -> String? {
        lock.withLock {
            guard let entry = entries[profile.id], entry.settingsURL == settingsURL, entry.profile == profile else {
                entries[profile.id] = nil; return nil
            }
            return entry.key
        }
    }
    func store(_ key: String, profile: ProviderProfile, settingsURL: URL) {
        lock.withLock { entries[profile.id] = Entry(profile: profile, settingsURL: settingsURL, key: key) }
    }
    func invalidate(profileID: UUID) { _ = lock.withLock { entries.removeValue(forKey: profileID) } }
}
