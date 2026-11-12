import Foundation

/// Nonsecret provider configuration; credential ownership and approval live outside this record.
struct ProviderProfile: Codable, Equatable, Sendable {
    enum ConnectionKind: String, Codable, Sendable { case cloud, local }
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
        static let maximumOutputTokens = 131_072
        static let maximumReservedTokens = maximumOutputTokens * 3
        static let defaultTokenBudget = maximumOutputTokens
        var requestBudget: Int
        var tokenBudget: Int
        // Nil preserves the byte representation and total-reservation semantics of legacy profiles.
        var nativeOutputLimit: Bool? = nil
        // A caller-selected conservative input/output envelope; nil delegates limits to the server.
        var contextWindow: Int? = nil

        init(requestBudget: Int = 3, tokenBudget: Int? = nil, nativeOutputLimit: Bool? = nil) {
            self.requestBudget = requestBudget
            self.tokenBudget = tokenBudget ?? Self.maximumOutputTokens
            self.nativeOutputLimit = nativeOutputLimit ?? (tokenBudget == nil ? true : nil)
        }
        static func tokenBudget(from text: String) -> Int? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return defaultTokenBudget }
            guard value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(value), (1...maximumOutputTokens).contains(number) else { return nil }
            return number
        }
        var outputTokensPerRequest: Int {
            nativeOutputLimit == nil ? max(1, tokenBudget / max(1, requestBudget)) : tokenBudget
        }
        /// Reservation accounting is an estimate in native mode, never a promise about server billing.
        var generationTokenBudget: Int {
            nativeOutputLimit == nil ? tokenBudget : tokenBudget * max(1, min(3, requestBudget))
        }
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
    var providerID: String? = nil
    var modelIDs: [String]? = nil
    var visionModelIDs: [String]? = nil
    // Nil preserves legacy records. Local legacy profiles default to no credential lookup.
    var usesCredential: Bool? = nil
    // Nil keeps legacy credential records readable without probing or moving Keychain items.
    var credentialNamespace: ConnectionKind? = nil
    var localMode = false
    var capabilities = Capabilities()
    var limits = Limits()

    var enabledModels: [String] { modelIDs ?? [model] }
    var connectionKind: ConnectionKind { localMode ? .local : .cloud }
    func permitsModel(_ id: String) -> Bool { enabledModels.contains(id) }
    static func validModel(_ value: String, protocolKind: ProtocolKind) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else { return false }
        if protocolKind == .geminiGenerateContent {
            return value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains)
        }
        return true
    }

    var allowsEmptyKey: Bool {
        localMode && protocolKind == .openaiCompatible && (try? origin()) != nil
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw CreatorPersistence.Failure.unsupportedVersion }
        guard credentialNamespace.map({ $0 == connectionKind }) ?? true else { throw CreatorPersistence.Failure.invalidRecord }
        guard configurationRevision >= 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !model.isEmpty, model.utf8.count <= 128,
              !model.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains),
              (1...3).contains(limits.requestBudget), (1...Limits.maximumOutputTokens).contains(limits.tokenBudget)
        else { throw CreatorPersistence.Failure.invalidRecord }
        guard (1...64).contains(enabledModels.count), Set(enabledModels).count == enabledModels.count,
              enabledModels.contains(model), enabledModels.allSatisfy({ Self.validModel($0, protocolKind: protocolKind) }),
              Set(visionModelIDs ?? []).isSubset(of: Set(enabledModels)),
              providerID.map({ CreatorProviderCatalog.entry($0) != nil }) ?? true,
              limits.contextWindow.map({ (256...2_097_152).contains($0) && limits.tokenBudget <= $0 }) ?? true
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
              LLMLocalEndpoint.safeEncoding(components),
              !components.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.url != nil else { throw CreatorPersistence.Failure.invalidRecord }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let local = protocolKind == .openaiCompatible && localMode && LLMLocalEndpoint.allows(host)
        guard !localMode || local, scheme == "https" || local else { throw CreatorPersistence.Failure.invalidRecord }
        return Origin(scheme: scheme, host: host, port: components.port ?? (scheme == "https" ? 443 : 80))
    }
}
