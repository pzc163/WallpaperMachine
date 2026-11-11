import Foundation

/// Nonsecret provider configuration; credential ownership and approval live outside this record.
struct ProviderProfile: Codable, Equatable, Sendable {
    enum ProtocolKind: String, Codable, CaseIterable, Sendable {
        case openaiCompatible, anthropicMessages, geminiGenerateContent
    }
    struct Capabilities: Codable, Equatable, Sendable {
        enum JSONMode: String, Codable, Sendable { case automatic, required, schema, disabled }
        // Optional so S1.1 canonical records re-encode byte-for-byte when the field is absent.
        var jsonMode: JSONMode? = nil
        var requestsUsage = true
        var filtersLeadingThinkBlock = false
    }
    struct Limits: Codable, Equatable, Sendable {
        var requestBudget = 3
        var tokenBudget = 16_384
    }
    struct Origin: Codable, Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    var schemaVersion = 1
    var id = UUID()
    var configurationRevision = 0
    var configurationID = UUID()
    var name: String
    var protocolKind: ProtocolKind
    var baseURL: String
    var model: String
    var localMode = false
    var capabilities = Capabilities()
    var limits = Limits()

    var allowsEmptyKey: Bool {
        localMode && protocolKind == .openaiCompatible && (try? origin()) != nil
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw CreatorPersistence.Failure.unsupportedVersion }
        guard configurationRevision >= 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !model.isEmpty, model.utf8.count <= 128,
              !model.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains),
              (1...3).contains(limits.requestBudget), (1...100_000).contains(limits.tokenBudget)
        else { throw CreatorPersistence.Failure.invalidRecord }
        if protocolKind != .openaiCompatible, capabilities != Capabilities() {
            throw CreatorPersistence.Failure.invalidRecord
        }
        if protocolKind == .geminiGenerateContent {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard model.unicodeScalars.allSatisfy(allowed.contains) else { throw CreatorPersistence.Failure.invalidRecord }
        }
        _ = try origin()
    }

    /// A parsed target for future credential comparison, never proof that credentials are authorized.
    func origin() throws -> Origin {
        guard !baseURL.isEmpty, baseURL.utf8.count <= 2048,
              baseURL.utf8.allSatisfy({ (33...126).contains($0) }),
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              var host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedHost?.contains("%") == false,
              !components.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.url != nil else { throw CreatorPersistence.Failure.invalidRecord }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let local = protocolKind == .openaiCompatible && localMode && ["127.0.0.1", "localhost", "::1"].contains(host)
        guard !localMode || local, scheme == "https" || local else { throw CreatorPersistence.Failure.invalidRecord }
        return Origin(scheme: scheme, host: host, port: components.port ?? (scheme == "https" ? 443 : 80))
    }
}
