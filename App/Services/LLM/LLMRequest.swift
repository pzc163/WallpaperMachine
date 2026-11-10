import Foundation

/// Bounded text-only input; the caller owns the system instruction, never the provider response.
struct LLMRequest: Sendable {
    struct Message: Sendable {
        enum Role: String, Sendable { case user, assistant }
        let role: Role
        let content: String
    }
    let system: String
    let messages: [Message]
    var maxOutputTokens = 4096

    var systemInstruction: String { system + "\nReturn one complete JSON object only, without Markdown or reasoning." }
    func validate() throws {
        guard !system.isEmpty, (1...32).contains(messages.count), messages.last?.role == .user,
              messages.allSatisfy({ !$0.content.isEmpty && $0.content.utf8.count <= 16 * 1024 }),
              system.utf8.count <= 16 * 1024,
              messages.reduce(system.utf8.count, { $0 + $1.content.utf8.count }) <= 16 * 1024,
              (1...100_000).contains(maxOutputTokens) else { throw LLMFailure.invalidInput }
    }
}
