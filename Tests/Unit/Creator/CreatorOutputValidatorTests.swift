import XCTest
@testable import WallpaperMachine

final class CreatorOutputValidatorTests: XCTestCase {
    func testEveryTemplateAndPresetCompilesWithMatchingNativeControls() throws {
        for definition in CreatorTemplateCatalog.all {
            for preset in definition.presets {
                var object = try CreatorGenerationFixtures.object(definition.id, parameters: preset.parameters)
                object["properties"] = preset.parameters.mapValues { ["default": $0.json] }
                let output = try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object))
                let compiled = try CreatorTemplateCompiler.compile(output, projectID: UUID())
                let files = try CreatorBundleManifest.files(for: compiled.specification, presentation: compiled.presentation)
                let project = try XCTUnwrap(JSONSerialization.jsonObject(with: files["project.json"]!) as? [String: Any])
                let properties = try XCTUnwrap((project["general"] as? [String: Any])?["properties"] as? [String: [String: Any]])
                XCTAssertEqual(Set(properties.keys), Set(preset.parameters.keys))
                for (key, value) in preset.parameters {
                    let json = try CreatorOutputSchema.encode(["value": try XCTUnwrap(properties[key]?["value"])])
                    XCTAssertEqual(try CreatorJSON.parse(String(decoding: json, as: UTF8.self)).object?["value"]?.parameter, value)
                }
                XCTAssertEqual(project["title"] as? String, output.presentation.title)
                XCTAssertEqual(project["description"] as? String, output.presentation.summary)
            }
        }
    }
    func testSingleWholeFenceAndCRLFAreAcceptedWithoutSearchingProse() throws {
        let raw = try CreatorGenerationFixtures.output()
        let expected = try CreatorOutputValidator.parse(raw)
        XCTAssertEqual(try CreatorOutputValidator.parse(" \n" + CreatorGenerationFixtures.fenced(raw) + "\n "), expected)
        XCTAssertEqual(try CreatorOutputValidator.parse(CreatorGenerationFixtures.fenced(raw).replacingOccurrences(of: "\n", with: "\r\n")), expected)
        for text in ["Explanation " + raw, raw + raw, CreatorGenerationFixtures.fenced(raw) + "\ntrailer",
                     CreatorGenerationFixtures.fenced(raw) + CreatorGenerationFixtures.fenced(raw),
                     String(CreatorGenerationFixtures.fenced(raw).dropLast()), CreatorGenerationFixtures.fenced(raw).replacingOccurrences(of: "json\n", with: "javascript\n")] {
            XCTAssertThrowsError(try CreatorOutputValidator.parse(text)) { XCTAssertEqual($0 as? CreatorGenerationFailure, .malformedOutput) }
        }
    }
    func testDuplicateKeysIncludingEscapedAndNestedKeysAreRejected() throws {
        let raw = try CreatorGenerationFixtures.output()
        let duplicates = [
            raw.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schema\\u0056ersion\":1"),
            raw.replacingOccurrences(of: "\"primaryHue\":220", with: "\"primaryHue\":220,\"primaryHue\":220"),
            raw.replacingOccurrences(of: "\"properties\":{}", with: "\"properties\":{\"primaryHue\":{\"default\":220,\"default\":220}}"),
        ]
        for value in duplicates {
            XCTAssertNotEqual(value, raw)
            XCTAssertThrowsError(try CreatorOutputValidator.parse(value)) { XCTAssertEqual($0 as? CreatorGenerationFailure, .malformedOutput) }
        }
    }
    func testJSONGrammarRejectsTruncationNonfiniteInvalidNumbersAndSurrogates() throws {
        let raw = try CreatorGenerationFixtures.output()
        for invalid in ["NaN", "Infinity", "1e309", "01", "1.", "+1", "1e", "--1"] {
            XCTAssertThrowsError(try CreatorOutputValidator.parse(raw.replacingOccurrences(of: "\"primaryHue\":220", with: "\"primaryHue\":" + invalid)))
        }
        for invalid in [String(raw.dropLast()), raw + " trailing", "[{}]", raw.replacingOccurrences(of: "\"title\":\"夜色🌙\"", with: "\"title\":\"\\uD800\"")] {
            XCTAssertThrowsError(try CreatorOutputValidator.parse(invalid))
        }
        XCTAssertThrowsError(try CreatorJSON.parse(String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9)))
    }
    func testCodeAssetsCapabilitiesAndPathKeysArePolicyViolations() throws {
        for field in ["files", "code", "capabilities", "assets", "path", "../escape.js", "unexpected"] {
            var object = try CreatorGenerationFixtures.object()
            object[field] = ["path": "../outside.js", "content": "while(true){}"]
            XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object))) {
                XCTAssertEqual($0 as? CreatorGenerationFailure, .policyViolation)
                XCTAssertFalse(String(reflecting: $0).contains("outside"))
            }
        }
        for id in ["../stars-v2", "https://example.invalid/x", "stars-v1", "unknown"] {
            var object = try CreatorGenerationFixtures.object(); object["templateID"] = id
            XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object))) { XCTAssertEqual($0 as? CreatorGenerationFailure, .policyViolation) }
        }
    }
    func testMissingRootFieldsWrongVersionAndWrongTypesNeverCoerce() throws {
        for key in ["schemaVersion", "templateID", "title", "summary", "parameters", "properties"] {
            var object = try CreatorGenerationFixtures.object(); object.removeValue(forKey: key)
            XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object)))
        }
        for value: Any in [true, "1", 2, 1.5, NSNull()] {
            var object = try CreatorGenerationFixtures.object(); object["schemaVersion"] = value
            XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object)))
        }
        for key in ["parameters", "properties"] {
            var object = try CreatorGenerationFixtures.object(); object[key] = []
            XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object)))
        }
    }
    func testParameterCompletenessTypesRangesAndEnumsStayNative() throws {
        for definition in CreatorTemplateCatalog.all {
            for parameter in definition.parameters {
                var object = try CreatorGenerationFixtures.object(definition.id)
                var parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
                parameters.removeValue(forKey: parameter.id); object["parameters"] = parameters
                XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object)))
                let invalid: [Any]
                switch parameter.domain {
                case .number(let range, _, let integer): invalid = [true, "1", range.lowerBound - 0.1, range.upperBound + 0.1] + (integer ? [1.5] : [])
                case .bool: invalid = [0, 1, "false", NSNull()]
                case .choice: invalid = ["../bad", "https://bad.invalid", false, 0]
                }
                for value in invalid {
                    parameters[parameter.id] = value; object["parameters"] = parameters
                    XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object)), parameter.id)
                }
            }
        }
    }
    func testPropertySubsetDefaultsMustAgreeAndCannotOverrideControlMetadata() throws {
        var object = try CreatorGenerationFixtures.object()
        object["properties"] = ["primaryHue": ["default": 220]]
        _ = try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object))
        for properties: [String: Any] in [
            ["primaryHue": ["default": 221]], ["primaryHue": ["default": "220"]],
            ["primaryHue": ["default": 220, "max": 999]], ["primaryHue": [:]], ["onClick": ["default": "run()"]]
        ] {
            object["properties"] = properties
            XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object)))
        }
    }
    func testUnicodeScalarBoundsControlsAndLiteralMarkupAreSafeMetadata() throws {
        var object = try CreatorGenerationFixtures.object()
        object["title"] = String(repeating: "🌙", count: 60)
        object["summary"] = String(repeating: "星", count: 240)
        _ = try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object))
        for key in ["title", "summary"] {
            for value in ["", "   ", "hello\nworld", "hello\n", "hello\r", "hello\u{2028}", "a\u{0}b", "a\u{202e}b", String(repeating: "🌙", count: key == "title" ? 61 : 241)] {
                var changed = object; changed[key] = value
                XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(changed)))
            }
        }
        object["title"] = "<script>alert(1)</script>"
        let output = try CreatorOutputValidator.parse(CreatorGenerationFixtures.text(object))
        let compiled = try CreatorTemplateCompiler.compile(output, projectID: UUID())
        let original = try CreatorTemplate.files(for: compiled.specification)
        let bundle = try CreatorBundleManifest.files(for: compiled.specification, presentation: compiled.presentation)
        XCTAssertEqual(bundle["index.html"], original["index.html"])
        XCTAssertFalse(String(decoding: bundle["index.html"]!, as: UTF8.self).contains("alert(1)"))
    }
    func testByteLimitAppliesBeforeWhitespaceAndFenceRemoval() throws {
        let raw = try CreatorGenerationFixtures.output()
        let exact = raw + String(repeating: " ", count: 16 * 1024 - raw.utf8.count)
        _ = try CreatorOutputValidator.parse(exact)
        XCTAssertThrowsError(try CreatorOutputValidator.parse(exact + " "))
        XCTAssertThrowsError(try CreatorOutputValidator.parse(CreatorGenerationFixtures.fenced(exact)))
    }
}
