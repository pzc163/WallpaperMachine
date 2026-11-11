import XCTest
@testable import WallpaperMachine

final class CreatorPromptBuilderTests: XCTestCase {
    func testConcreteClockExampleIsFlatCompleteAndPassesUnchangedNativeValidator() throws {
        let input = try CreatorPromptBuilder.build(prompt: "时钟", base: nil, maxOutputTokens: 1024)
        let examples = input.system.components(separatedBy: .newlines).filter {
            (try? CreatorOutputValidator.parse($0)) != nil
        }
        XCTAssertEqual(examples.count, 1)
        let example = try XCTUnwrap(examples.first)
        let output = try CreatorOutputValidator.parse(example)
        XCTAssertEqual(output.templateID, "clock-v2")
        XCTAssertEqual(output.parameters, try CreatorTemplateCatalog.definition("clock-v2").defaults)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])
        XCTAssertEqual((object["properties"] as? [String: Any])?.count, 0)
        let parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
        XCTAssertNotNil(parameters["backgroundMotion"]); XCTAssertNil(parameters["motionSpeed"]); XCTAssertNil(parameters["clockVisible"])
        XCTAssertTrue(parameters.values.allSatisfy { $0 is String || $0 is NSNumber })
    }

    func testProviderSchemaUsesPortableClosedObjectsAndNativeTemplateKeys() throws {
        let output = try CreatorStructuredOutputSchema.make()
        let root = try output.object()
        func portable(_ node: [String: Any]) throws {
            XCTAssertTrue(Set(node.keys).isSubset(of: ["type", "enum", "properties", "required", "additionalProperties", "anyOf", "description"]))
            if let branches = node["anyOf"] as? [[String: Any]] {
                XCTAssertNil(node["properties"], "llama.cpp cannot combine properties and anyOf at the same node")
                for branch in branches { try portable(branch) }
            } else if node["type"] as? String == "object" {
                let fields = try XCTUnwrap(node["properties"] as? [String: [String: Any]])
                XCTAssertEqual(node["additionalProperties"] as? Bool, false)
                XCTAssertEqual(Set(try XCTUnwrap(node["required"] as? [String])), Set(fields.keys))
                for field in fields.values { try portable(field) }
            }
        }
        try portable(root)
        XCTAssertNil(root["anyOf"])
        XCTAssertEqual(output.name, "template_parameter_output_v1")
        let fields = try XCTUnwrap(root["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(fields.keys), ["schemaVersion", "templateID", "title", "summary", "parameters", "properties"])
        XCTAssertEqual(fields["schemaVersion"]?["enum"] as? [Int], [1])
        XCTAssertEqual(fields["templateID"]?["enum"] as? [String], CreatorTemplateCatalog.all.map(\.id))
        XCTAssertEqual((fields["properties"]?["properties"] as? [String: Any])?.count, 0)
        let branches = try XCTUnwrap(fields["parameters"]?["anyOf"] as? [[String: Any]])
        XCTAssertEqual(branches.count, CreatorTemplateCatalog.all.count)
        for (branch, template) in zip(branches, CreatorTemplateCatalog.all) {
            let fields = try XCTUnwrap(branch["properties"] as? [String: [String: Any]])
            XCTAssertEqual(Set(fields.keys), Set(template.parameters.map(\.id)))
            for parameter in template.parameters {
                let native = CreatorOutputSchema.parameter(parameter)
                XCTAssertEqual(fields[parameter.id]?["type"] as? String, native["type"] as? String)
                XCTAssertEqual(fields[parameter.id]?["enum"] as? [String], native["enum"] as? [String])
            }
            for preset in template.presets {
                let parsed = try CreatorOutputValidator.parse(CreatorGenerationFixtures.output(template.id, parameters: preset.parameters))
                XCTAssertEqual(parsed.parameters, preset.parameters)
            }
        }
        XCTAssertEqual(output.schema, try CreatorStructuredOutputSchema.make().schema)
    }

    func testSchemaHintsDoNotReplaceNativeRangeTextOrTemplateBindingChecks() throws {
        var mismatch = try CreatorGenerationFixtures.object("stars-v2")
        mismatch["templateID"] = "clock-v2"
        XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(mismatch))) {
            XCTAssertEqual($0 as? CreatorGenerationFailure, .policyViolation)
        }
        var invalid = try CreatorGenerationFixtures.object("clock-v2")
        var parameters = invalid["parameters"] as! [String: Any]
        parameters["backgroundMotion"] = 999; invalid["parameters"] = parameters
        XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(invalid)))
        invalid = try CreatorGenerationFixtures.object("clock-v2"); invalid["title"] = "invalid\ntext"
        XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(invalid)))
    }

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
