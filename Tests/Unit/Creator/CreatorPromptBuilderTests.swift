import XCTest
@testable import WallpaperMachine

final class CreatorPromptBuilderTests: XCTestCase {
    func testCatalogAndBaseAreBoundedJSONContextWithoutProviderSecrets() throws {
        let definition = try CreatorTemplateCatalog.definition("stars-v2")
        let base = CreatorPromptBuilder.Base(revisionID: UUID(), revisionDigest: String(repeating: "a", count: 64),
            templateID: definition.id, parameters: definition.presets[1].parameters, title: "previous", summary: "base")
        let input = try CreatorPromptBuilder.build(prompt: "减少星点，只改密度", base: base, maxOutputTokens: 1024)
        try input.validate()
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.messages[0].content.utf8)) as? [String: Any])
        let previous = try XCTUnwrap(context["base"] as? [String: Any])
        XCTAssertEqual(previous["revisionID"] as? String, base.revisionID.uuidString.lowercased())
        XCTAssertEqual(previous["templateID"] as? String, definition.id)
        let parameters = try XCTUnwrap(previous["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["primaryHue"] as? Double, 165)
        XCTAssertEqual(parameters["starDensity"] as? Double, 1)
        XCTAssertFalse(input.system.contains(LLMTestFixtures.key))
        XCTAssertFalse(input.messages[0].content.contains(base.revisionDigest))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: CreatorOutputSchema.promptCatalog()) as? [String: Any])
        let templates = try XCTUnwrap(catalog["templates"] as? [[String: Any]])
        XCTAssertEqual(Set(templates.compactMap { $0["templateID"] as? String }), Set(CreatorTemplateCatalog.all.map(\.id)))
        for template in templates {
            let id = try XCTUnwrap(template["templateID"] as? String)
            let definition = try CreatorTemplateCatalog.definition(id)
            XCTAssertEqual((template["parameters"] as? [[String: Any]])?.count, definition.parameters.count)
            XCTAssertEqual((template["presets"] as? [[String: Any]])?.count, 2)
            XCTAssertNotNil(template["resourceLimits"])
        }
    }
    func testExportedSchemaBoundariesAgreeWithValidatorAndCatalog() throws {
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: CreatorOutputSchema.document()) as? [String: Any])
        let definitions = try XCTUnwrap(document["$defs"] as? [String: [String: Any]])
        XCTAssertEqual(definitions.count, 3)
        for template in CreatorTemplateCatalog.all {
            let branch = try XCTUnwrap(definitions[template.id])
            XCTAssertEqual(branch["additionalProperties"] as? Bool, false)
            let fields = try XCTUnwrap(branch["properties"] as? [String: [String: Any]])
            let parameters = try XCTUnwrap(fields["parameters"]?["properties"] as? [String: [String: Any]])
            XCTAssertEqual(Set(parameters.keys), Set(template.parameters.map(\.id)))
            for (id, schema) in parameters {
                let values: [Any]
                if let choices = schema["enum"] as? [String] { values = choices }
                else if schema["type"] as? String == "boolean" { values = [true, false] }
                else { values = [try XCTUnwrap(schema["minimum"]), try XCTUnwrap(schema["maximum"])] }
                for value in values {
                    var object = try CreatorGenerationFixtures.object(template.id)
                    var inputs = try XCTUnwrap(object["parameters"] as? [String: Any])
                    inputs[id] = value; object["parameters"] = inputs
                    _ = try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object))
                }
            }
        }
    }
    func testFromScratchOmitsBaseAndPromptLimitsAreCheckedBeforeSending() throws {
        let input = try CreatorPromptBuilder.build(prompt: "渐变", base: nil, maxOutputTokens: 1024)
        let user = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.messages[0].content.utf8)) as? [String: Any])
        XCTAssertNil(user["base"])
        for prompt in ["", "  \n", String(repeating: "a", count: 2049), "bad\u{0}input"] {
            XCTAssertThrowsError(try CreatorPromptBuilder.build(prompt: prompt, base: nil, maxOutputTokens: 1024))
        }
        let largest = try CreatorPromptBuilder.build(prompt: String(repeating: "a", count: 2048), base: nil, maxOutputTokens: 1024)
        try largest.validate()
        XCTAssertEqual(CreatorPromptBuilder.promptSummary("hello\n\tworld"), "hello world")
        XCTAssertEqual(CreatorPromptBuilder.promptSummary(String(repeating: "🌙", count: 300)).unicodeScalars.count, 240)
    }
}
