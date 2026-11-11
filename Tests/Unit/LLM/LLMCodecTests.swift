import XCTest
@testable import WallpaperMachine

final class LLMCodecTests: XCTestCase {
    func testAllProtocolsDecodeBytewiseAndPreserveLiteralThoughtTagsInJSON() throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let result = try LLMTestFixtures.decode(LLMTestFixtures.body(for: kind), profile: LLMTestFixtures.profile(kind))
            XCTAssertEqual(result.text, LLMTestFixtures.answer)
            XCTAssertEqual(result.usage.inputTokens, 12)
            XCTAssertEqual(result.usage.outputTokens, 8)
            XCTAssertFalse(result.text.contains("private"))
        }
    }
    func testOpenAIUsageOnlyTailAndUnknownUsageAreDifferent() throws {
        let profile = LLMTestFixtures.profile()
        let known = try LLMTestFixtures.decode(LLMTestFixtures.openAI(), profile: profile, chunkSize: 17)
        XCTAssertEqual(known.usage.totalTokens, 20)
        let unknown = try LLMTestFixtures.decode(LLMTestFixtures.openAI(usage: nil), profile: profile)
        XCTAssertTrue(unknown.usage.isUnknown)
        XCTAssertNil(unknown.usage.outputTokens)
    }
    func testMissingUsageIsUnknownForEveryProtocol() throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            var parser = SSEParser(), data = Data()
            for event in try parser.append(LLMTestFixtures.body(for: kind)) {
                if event.data == "[DONE]" { data.append(Data("data: [DONE]\n\n".utf8)); continue }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any])
                if (object["candidates"] as? [Any])?.isEmpty == true { continue }
                object.removeValue(forKey: "usage"); object.removeValue(forKey: "usageMetadata")
                if var message = object["message"] as? [String: Any] {
                    message.removeValue(forKey: "usage"); object["message"] = message
                }
                data.append(try LLMTestFixtures.frame(object, event: event.name))
            }
            let response = try LLMTestFixtures.decode(data, profile: LLMTestFixtures.profile(kind))
            XCTAssertEqual(response.text, LLMTestFixtures.answer)
            XCTAssertTrue(response.usage.isUnknown)
            XCTAssertNil(response.usage.inputTokens); XCTAssertNil(response.usage.outputTokens)
        }
    }
    func testOpenAILeadingThoughtTagsAreStrippedAcrossContentDeltasWithLegacyProfiles() throws {
        let fragments = [" <th", "ink>hidden {bad JSON}", "</thi", "nk>", LLMTestFixtures.answer]
        var data = Data()
        for part in fragments { data.append(try LLMTestFixtures.frame(["choices": [["index": 0, "delta": ["content": part], "finish_reason": NSNull()]]])) }
        data.append(try LLMTestFixtures.openAI(""))
        var profile = LLMTestFixtures.profile(); profile.capabilities.filtersLeadingThinkBlock = true
        XCTAssertEqual(try LLMTestFixtures.decode(data, profile: profile).text, LLMTestFixtures.answer)
        profile.capabilities.filtersLeadingThinkBlock = false
        XCTAssertEqual(try LLMTestFixtures.decode(data, profile: profile).text, LLMTestFixtures.answer)
        profile.capabilities.filtersLeadingThinkBlock = true
        XCTAssertThrowsError(try LLMTestFixtures.decode(LLMTestFixtures.openAI("<think>not closed"), profile: profile))
        XCTAssertThrowsError(try LLMTestFixtures.decode(LLMTestFixtures.openAI("<analysis>unknown</analysis>{}"), profile: profile))
    }
    func testOpenAITypedThinkingBlocksAndOtherChoicesNeverEnterAnswer() throws {
        var data = try LLMTestFixtures.frame(["choices": [
            ["index": 1, "delta": ["content": "not selected"], "finish_reason": "stop"],
            ["index": 0, "delta": ["content": [["type": "thinking", "thinking": "private"], ["type": "text", "text": "{}"]]], "finish_reason": "stop"]]])
        data.append(Data("data: [DONE]\n\n".utf8))
        XCTAssertEqual(try LLMTestFixtures.decode(data, profile: LLMTestFixtures.profile()).text, "{}")
    }
    func testAnthropicCumulativeUsageIsMergedAndThinkingStartDeltaAndSignatureAreSkipped() throws {
        let result = try LLMTestFixtures.decode(LLMTestFixtures.anthropic(), profile: LLMTestFixtures.profile(.anthropicMessages))
        XCTAssertEqual(result.usage.inputTokens, 12)
        XCTAssertEqual(result.usage.outputTokens, 8)
        XCTAssertNil(result.usage.totalTokens)
        XCTAssertEqual(result.text, LLMTestFixtures.answer)
    }
    func testGeminiTrailingUsageIncludesThoughtTokensWithoutThoughtText() throws {
        let result = try LLMTestFixtures.decode(LLMTestFixtures.gemini(), profile: LLMTestFixtures.profile(.geminiGenerateContent))
        XCTAssertEqual(result.usage.totalTokens, 24)
        XCTAssertEqual(result.usage.thinkingTokens, 4)
        XCTAssertEqual(result.text, LLMTestFixtures.answer)
    }
    func testMissingEndMarkersAndPrematureEOFNeverReturnSuccess() throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            var bytes = try LLMTestFixtures.body(for: kind)
            if kind == .geminiGenerateContent {
                bytes = try LLMTestFixtures.frame(["candidates": [["index": 0, "content": ["parts": [["text": "{}"]]]]]])
            } else {
                let marker = kind == .openaiCompatible ? "data: [DONE]" : "event: message_stop"
                let string = String(decoding: bytes, as: UTF8.self)
                bytes = Data(string.components(separatedBy: marker)[0].utf8)
            }
            XCTAssertThrowsError(try LLMTestFixtures.decode(bytes, profile: LLMTestFixtures.profile(kind)), kind.rawValue)
        }
    }
    func testRefusalTokenLimitToolsAndStreamErrorsAreRejected() throws {
        for reason in ["length", "content_filter", "tool_calls"] {
            XCTAssertThrowsError(try LLMTestFixtures.decode(LLMTestFixtures.openAI(reason: reason), profile: LLMTestFixtures.profile()))
        }
        for kind in ProviderProfile.ProtocolKind.allCases {
            let event = kind == .anthropicMessages ? "error" : nil
            let bytes = try LLMTestFixtures.frame(["type": "error", "error": ["message": LLMTestFixtures.key]], event: event)
            XCTAssertThrowsError(try LLMTestFixtures.decode(bytes, profile: LLMTestFixtures.profile(kind))) {
                XCTAssertFalse(String(reflecting: $0).contains(LLMTestFixtures.key))
            }
        }
        let blocked = try LLMTestFixtures.frame(["promptFeedback": ["blockReason": "SAFETY"]])
        XCTAssertThrowsError(try LLMTestFixtures.decode(blocked, profile: LLMTestFixtures.profile(.geminiGenerateContent)))
    }
    func testProtocolOrderMismatchesInvalidUsageAndOversizedOutputAreRejected() throws {
        let mismatch = try LLMTestFixtures.frame(["type": "message_stop"], event: "message_delta")
        XCTAssertThrowsError(try LLMTestFixtures.decode(mismatch, profile: LLMTestFixtures.profile(.anthropicMessages)))
        for count: Any in [-1, true, 1.5, 100_000_001] {
            XCTAssertThrowsError(try LLMTestFixtures.decode(LLMTestFixtures.openAI(usage: ["prompt_tokens": count]), profile: LLMTestFixtures.profile()))
        }
        XCTAssertThrowsError(try LLMTestFixtures.decode(LLMTestFixtures.openAI("{\"title\":\"" + String(repeating: "a", count: 16 * 1024) + "\"}"), profile: LLMTestFixtures.profile()))
        XCTAssertThrowsError(try LLMTestFixtures.decode(LLMTestFixtures.openAI("{\"incomplete\":"), profile: LLMTestFixtures.profile()))
    }
    func testRequestShapesUseCorrectSystemFieldsPathsAndJSONMode() throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let profile = LLMTestFixtures.profile(kind)
            let request = try LLMRequestDescriptor.make(profile: profile, input: LLMTestFixtures.input, jsonMode: true)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            switch kind {
            case .openaiCompatible:
                XCTAssertEqual(request.url.path, "/v1/chat/completions")
                XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
                XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
                XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["role"], "system")
            case .anthropicMessages:
                XCTAssertEqual(request.url.path, "/v1/messages")
                XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
                XCTAssertNotNil(body["system"])
                XCTAssertFalse((body["messages"] as? [[String: String]])?.contains { $0["role"] == "system" } ?? true)
            case .geminiGenerateContent:
                XCTAssertEqual(request.url.path, "/v1beta/models/fixture-model:streamGenerateContent")
                XCTAssertEqual(request.url.query, "alt=sse")
                XCTAssertNotNil(body["systemInstruction"])
                XCTAssertNil(body["responseMimeType"])
                XCTAssertEqual((body["generationConfig"] as? [String: Any])?["responseMimeType"] as? String, "application/json")
            }
            XCTAssertFalse(request.url.absoluteString.contains(LLMTestFixtures.key))
        }
    }
    func testOpenAIStructuredOutputModesPreserveLegacyJSONAndNativeRequestShape() throws {
        let input = try CreatorPromptBuilder.build(prompt: "时钟", base: nil, maxOutputTokens: 64)
        let modes: [ProviderProfile.Capabilities.JSONMode?] = [nil, .automatic, .required, .schema, .disabled]
        for mode in modes {
            var profile = LLMTestFixtures.profile(); profile.capabilities.jsonMode = mode
            let descriptor = try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: true)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptor.body) as? [String: Any])
            let format = body["response_format"] as? [String: Any]
            if mode == .disabled { XCTAssertNil(format) }
            else if mode == .required { XCTAssertEqual(format?["type"] as? String, "json_object"); XCTAssertNil(format?["json_schema"]) }
            else {
                XCTAssertEqual(format?["type"] as? String, "json_schema")
                let schema = try XCTUnwrap(format?["json_schema"] as? [String: Any])
                XCTAssertEqual(Set(schema.keys), ["name", "strict", "schema"])
                XCTAssertEqual(schema["name"] as? String, "template_parameter_output_v1")
                XCTAssertEqual(schema["strict"] as? Bool, true)
                XCTAssertEqual(try CreatorOutputSchema.encode(try XCTUnwrap(schema["schema"])), try XCTUnwrap(input.structuredOutput).schema)
            }
            XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
            XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], input.systemInstruction)
        }
        var profile = LLMTestFixtures.profile(); profile.capabilities.jsonMode = .schema
        XCTAssertThrowsError(try LLMRequestDescriptor.make(profile: profile, input: LLMTestFixtures.input, jsonMode: true))
        let disabled = try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false)
        XCTAssertNil((try JSONSerialization.jsonObject(with: disabled.body) as? [String: Any])?["response_format"])
    }

    func testStructuredOutputMetadataIsBoundedAndNotAddedToOtherProtocols() throws {
        var input = try CreatorPromptBuilder.build(prompt: "渐变", base: nil, maxOutputTokens: 64)
        for kind in [ProviderProfile.ProtocolKind.anthropicMessages, .geminiGenerateContent] {
            let descriptor = try LLMRequestDescriptor.make(profile: LLMTestFixtures.profile(kind), input: input, jsonMode: true)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptor.body) as? [String: Any])
            XCTAssertNil(body["response_format"]); XCTAssertNil(body["json_schema"])
        }
        for schema in [Data("[1]".utf8), Data("bad".utf8), Data(#"{"type":"array"}"#.utf8), Data(repeating: 32, count: 32769)] {
            input.structuredOutput = .init(name: "safe_name", schema: schema)
            XCTAssertThrowsError(try input.validate()) { XCTAssertEqual($0 as? LLMFailure, .invalidInput) }
        }
        for name in ["", "../path", "key\nvalue", String(repeating: "x", count: 65)] {
            input.structuredOutput = .init(name: name, schema: Data(#"{"type":"object"}"#.utf8))
            XCTAssertThrowsError(try input.validate()) { XCTAssertEqual($0 as? LLMFailure, .invalidInput) }
        }
    }

    func testOpenAICompatibilityOptionsCanBeOmittedWithoutAnotherRequest() throws {
        var profile = LLMTestFixtures.profile(); profile.baseURL += "/v1"; profile.capabilities.requestsUsage = false
        let request = try LLMRequestDescriptor.make(profile: profile, input: LLMTestFixtures.input, jsonMode: false)
        XCTAssertEqual(request.url.path, "/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertNil(body["response_format"]); XCTAssertNil(body["stream_options"])
    }
}
