import Foundation

/// Explicit local discovery uses the entered key in memory, never saved credentials or a model call.
struct LLMModelCatalog: Sendable {
    var transport = LLMStreamTransport(limits: .init(maximumBytes: 128 * 1024, timeout: 25))
    /// Discovery depends only on the draft endpoint; unfinished model/name/budget fields are irrelevant.
    static func target(for draft: ProviderProfile) throws -> ProviderProfile {
        guard draft.localMode, draft.protocolKind == .openaiCompatible else { throw LLMFailure.invalidInput }
        _ = try draft.origin()
        var target = ProviderProfile(name: "Discovery", protocolKind: .openaiCompatible,
                                     baseURL: draft.baseURL, model: "discovery")
        target.localMode = true
        try target.validate()
        return target
    }
    func fetch(profile: ProviderProfile, key: String) async throws -> [String] {
        guard profile.localMode, profile.protocolKind == .openaiCompatible,
              key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw LLMFailure.invalidInput }
        let target = try Self.target(for: profile)
        let url = try LLMRequestDescriptor.endpoint(target, version: nil, suffix: "models")
        let descriptor = LLMRequestDescriptor(url: url, headers: [:], body: Data(), authentication: .bearer, method: "GET")
        let request = try ProviderCredentialStore.Grant(profile: target, key: key).request(descriptor)
        let response = try await transport.perform(request, decoder: Decoder()) { task in
            try Task.checkCancellation(); task.resume()
        }
        return try JSONDecoder().decode([String].self, from: Data(response.text.utf8))
    }
    private struct Decoder: LLMProtocolCodec {
        var acceptsJSON: Bool { true }
        var models: [String]?
        mutating func consume(_ event: SSEParser.Event) throws { throw LLMFailure.protocolViolation }
        mutating func consumeJSON(_ data: Data) throws {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]], rows.count <= 512 else { throw LLMFailure.protocolViolation }
            var ids = Set<String>()
            for row in rows {
                guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                      !id.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else { throw LLMFailure.protocolViolation }
                ids.insert(id)
            }
            models = ids.sorted()
        }
        func finish() throws -> LLMResponse {
            guard let models else { throw LLMFailure.truncated }
            return LLMResponse(text: String(decoding: try JSONEncoder().encode(models), as: UTF8.self))
        }
    }
}
