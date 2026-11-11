import XCTest
@testable import WallpaperMachine

enum CreatorGenerationFixtures {
    static func object(_ id: String = "stars-v2", parameters: [String: CreatorTemplateCatalog.Value]? = nil) throws -> [String: Any] {
        let definition = try CreatorTemplateCatalog.definition(id)
        return ["schemaVersion": 1, "templateID": id, "title": "夜色🌙", "summary": "缓慢变化的原生壁纸",
                "parameters": (parameters ?? definition.defaults).mapValues(\.json), "properties": [:] as [String: Any]]
    }
    static func text(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func output(_ id: String = "stars-v2", parameters: [String: CreatorTemplateCatalog.Value]? = nil) throws -> String {
        try text(object(id, parameters: parameters))
    }
    static func fenced(_ text: String) -> String {
        let fence = String(repeating: "\u{0060}", count: 3)
        return fence + "json\n" + text + "\n" + fence
    }
    static func response(_ text: String, kind: ProviderProfile.ProtocolKind) throws -> Data {
        switch kind {
        case .openaiCompatible: try LLMTestFixtures.openAI(text)
        case .anthropicMessages: try LLMTestFixtures.anthropic(text)
        case .geminiGenerateContent: try LLMTestFixtures.gemini(text)
        }
    }
}
