import Foundation

/// Credentials are bound to a saved configuration, never recovered from profile metadata alone.
actor ProviderCredentialStore {
    static let service = "WallpaperMachine.Creator.ProviderCredentials.v1"
    private struct Binding: Codable {
        let schemaVersion: Int
        let profileID: UUID
        let origin: ProviderProfile.Origin
        let configurationID: UUID
        let configurationRevision: Int
        let profileDigest: String
        let key: String
    }
    struct Grant: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        private let profile: ProviderProfile
        private let key: String
        init(profile: ProviderProfile, key: String) { self.profile = profile; self.key = key }
        var description: String { "ProviderCredentialGrant(<redacted>)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }

        func redacting(_ text: String) -> String {
            key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[redacted]")
        }

        func request(_ descriptor: LLMRequestDescriptor) throws -> URLRequest {
            guard var components = URLComponents(url: descriptor.url, resolvingAgainstBaseURL: false),
                  components.fragment == nil, components.user == nil, components.password == nil
            else { throw LLMFailure.invalidInput }
            let expectedQuery = profile.protocolKind == .geminiGenerateContent ? "alt=sse" : nil
            guard components.percentEncodedQuery == expectedQuery else { throw LLMFailure.invalidInput }
            components.query = nil
            var target = profile; target.baseURL = components.string ?? ""
            guard (try? target.origin()) == (try? profile.origin()), (try? target.origin()) != nil else { throw LLMFailure.staleProfile }
            var request = URLRequest(url: descriptor.url)
            guard ["POST", "GET"].contains(descriptor.method) else { throw LLMFailure.invalidInput }
            request.httpMethod = descriptor.method; request.httpBody = descriptor.method == "GET" ? nil : descriptor.body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(descriptor.method == "GET" ? "application/json" : "text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            switch (profile.protocolKind, descriptor.authentication) {
            case (.openaiCompatible, .bearer):
                guard descriptor.headers.isEmpty else { throw LLMFailure.invalidInput }
                if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            case (.anthropicMessages, .anthropic):
                guard descriptor.headers == ["anthropic-version": "2023-06-01"] else { throw LLMFailure.invalidInput }
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case (.geminiGenerateContent, .google):
                guard descriptor.headers.isEmpty else { throw LLMFailure.invalidInput }
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default: throw LLMFailure.invalidInput
            }
            return request
        }
    }
    private let cache = ProviderCredentialCache()
    private let calls: any KeychainItemCalls
    init(calls: any KeychainItemCalls = SystemKeychain()) { self.calls = calls }

    /// Only a future explicit credential action should call bind; changing a profile never calls it.
    func bind(_ key: String, to profile: ProviderProfile, settings: CreatorSettingsStore) async throws {
        try Self.validateKey(key, for: profile)
        try await settings.withCurrentProfile(profile) { _ in }
        cache.invalidate(profileID: profile.id)
        if key.isEmpty {
            LLMRequestCoordinator.shared.credentialChanged(at: settings.url, profileID: profile.id)
            return
        }
        do {
            let binding = Binding(schemaVersion: 1, profileID: profile.id, origin: try profile.origin(),
                configurationID: profile.configurationID, configurationRevision: profile.configurationRevision,
                profileDigest: try Self.digest(profile), key: key)
            try item(profile.id).write(CreatorPersistence.record(binding))
        } catch { throw LLMFailure.credentialsUnavailable }
        LLMRequestCoordinator.shared.credentialChanged(at: settings.url, profileID: profile.id)
        let cache = cache
        try await settings.withCurrentProfile(profile) { _ in
            if profile.allowsEmptyKey { cache.store(key, profile: profile, settingsURL: settings.url) }
        }
    }
    func resolve(for profile: ProviderProfile, settings: CreatorSettingsStore) async throws -> Grant {
        try await settings.withCurrentProfile(profile) { _ in }
        if let cached = cache.key(profile: profile, settingsURL: settings.url) {
            return Grant(profile: profile, key: cached)
        }
        if profile.allowsEmptyKey && profile.usesCredential != true {
            return Grant(profile: profile, key: "")
        }
        let key: String
        do {
            if let data = try item(profile.id).read() {
                guard data.count <= 16 * 1024 else { throw LLMFailure.credentialsUnavailable }
                let binding = try CreatorPersistence.decode(Binding.self, from: data)
                guard binding.schemaVersion == 1, binding.profileID == profile.id, binding.origin == (try profile.origin()),
                      binding.configurationID == profile.configurationID, binding.configurationRevision == profile.configurationRevision,
                      binding.profileDigest == (try Self.digest(profile)) else { throw LLMFailure.credentialsUnavailable }
                key = binding.key
            } else {
                guard profile.allowsEmptyKey else { throw LLMFailure.credentialsUnavailable }
                key = ""
            }
            try Self.validateKey(key, for: profile)
        } catch { throw LLMFailure.credentialsUnavailable }
        let cache = cache
        try await settings.withCurrentProfile(profile) { _ in cache.store(key, profile: profile, settingsURL: settings.url) }
        return Grant(profile: profile, key: key)
    }
    func remove(for profile: ProviderProfile, settings: CreatorSettingsStore) async throws {
        try await settings.withCurrentProfile(profile) { _ in }
        cache.invalidate(profileID: profile.id)
        if profile.allowsEmptyKey && profile.usesCredential != true { return }
        do { try item(profile.id).delete() } catch { throw LLMFailure.credentialsUnavailable }
        LLMRequestCoordinator.shared.credentialChanged(at: settings.url, profileID: profile.id)
    }
    private func item(_ id: UUID) -> KeychainGenericPassword {
        KeychainGenericPassword(service: Self.service, account: id.uuidString.lowercased(), label: Self.service, calls: calls)
    }
    private static func digest(_ profile: ProviderProfile) throws -> String { CreatorPersistence.hash(try CreatorPersistence.encode(profile)) }
    private static func validateKey(_ key: String, for profile: ProviderProfile) throws {
        guard (try? profile.validate()) != nil, profile.configurationRevision > 0,
              key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }),
              !key.isEmpty || profile.allowsEmptyKey else { throw LLMFailure.credentialsUnavailable }
    }
}
