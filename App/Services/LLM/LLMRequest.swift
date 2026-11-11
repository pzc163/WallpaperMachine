import Foundation

/// Bounded text-only input; the caller owns the system instruction, never the provider response.
struct LLMRequest: Sendable {
    struct Message: Sendable {
        enum Role: String, Sendable { case user, assistant }
        let role: Role
        let content: String
    }
    /// Native caller-owned grammar hints, separate from the bounded model/user text.
    struct StructuredOutput: Sendable {
        let name: String
        let schema: Data

        func object() throws -> [String: Any] {
            guard (1...64).contains(name.utf8.count),
                  name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  schema.count <= 32 * 1024,
                  let object = (try? JSONSerialization.jsonObject(with: schema)) as? [String: Any],
                  object["type"] as? String == "object" else { throw LLMFailure.invalidInput }
            return object
        }
    }
    let system: String
    let messages: [Message]
    var maxOutputTokens = 4096
    var structuredOutput: StructuredOutput? = nil
    var requiresJSON = true
    var nativeOutputLimit = false

    var systemInstruction: String { requiresJSON ? system + "\nReturn one complete JSON object only, without Markdown or reasoning." : system }
    func validate() throws {
        guard !system.isEmpty, (1...32).contains(messages.count), messages.last?.role == .user,
              messages.allSatisfy({ !$0.content.isEmpty && $0.content.utf8.count <= (requiresJSON ? 16 : 264) * 1024 }),
              system.utf8.count <= 16 * 1024,
              messages.reduce(system.utf8.count, { $0 + $1.content.utf8.count }) <= (requiresJSON ? 16 : 280) * 1024,
              (1...ProviderProfile.Limits.maximumOutputTokens).contains(maxOutputTokens) else { throw LLMFailure.invalidInput }
        _ = try structuredOutput?.object()
    }
}
