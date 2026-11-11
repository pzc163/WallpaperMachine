import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorProviderCenterTests: XCTestCase {
    func testPresetInventoryAndEveryTargetUsesSharedOriginPolicy() throws {
        let entries = CreatorProviderCatalog.entries
        XCTAssertEqual(entries.filter { !$0.local && !$0.custom }.count, 11)
        XCTAssertEqual(entries.filter { $0.local && !$0.custom }.count, 2)
        XCTAssertEqual(entries.filter(\.custom).count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        for entry in entries where !entry.custom {
            for endpoint in entry.endpoints {
                var profile = entry.profile(); profile.baseURL = endpoint; profile.model = "test-model"
                try profile.validate()
                XCTAssertEqual(profile.allowsEmptyKey, entry.local)
                if entry.local { XCTAssertNoThrow(try LLMModelCatalog.target(for: profile)) }
            }
        }
    }
    func testBrandAndModelIconsAreOfflineCompiledAssets() throws {
        for entry in CreatorProviderCatalog.entries {
            if let icon = entry.icon { XCTAssertNotNil(NSImage(named: "Provider-" + icon), icon) }
        }
        var profile = CreatorProviderCatalog.entry("lmstudio")!.profile(); profile.model = "local"
        for model in ["claude-test", "gemini-test", "grok-test", "qwen-test", "deepseek-test", "kimi-test", "glm-test"] {
            let icon = try XCTUnwrap(CreatorProviderCatalog.icon(profile: profile, model: model))
            XCTAssertNotNil(NSImage(named: "Provider-" + icon))
        }
        XCTAssertNil(CreatorProviderCatalog.entry("minicpm")?.icon, "The pinned library has no MiniCPM brand asset")
    }
    func testSelectingModelsSharesOneCredentialAndDoesNotChangeConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorSettingsStore(url: root.appendingPathComponent("settings.json"))
        var input = ProviderProfile(name: "Vendor", protocolKind: .openaiCompatible, baseURL: "https://example.test/v1", model: "one")
        input.modelIDs = ["one", "two"]
        var document = try await store.saveProfile(input, expectedRevision: 0)
        let profile = document.profiles[0], memory = MemoryKeychain(), credentials = ProviderCredentialStore(calls: memory)
        try await credentials.bind("fixture-secret", to: profile, settings: store)
        XCTAssertEqual(memory.readCount, 0)
        for id in ["one", "two", "one"] {
            document = try await store.selectProfile(profile.id, modelID: id, expectedRevision: document.revision)
            XCTAssertEqual(document.profiles[0], profile)
            XCTAssertEqual(document.selectedModel, id)
            let grant = try await credentials.resolve(for: profile, settings: store)
            var request = LLMRequest(system: "Fixture", messages: [.init(role: .user, content: "{}")]); request.modelID = id
            let description = try LLMRequestDescriptor.make(profile: profile, input: request, jsonMode: false)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: description.body) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, id)
            XCTAssertEqual(try grant.request(description).value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        }
        XCTAssertEqual(memory.readCount, 1)
        let reopened = try await CreatorSettingsStore(url: store.url).settings()
        XCTAssertEqual(reopened, document)
        do { _ = try await store.selectProfile(profile.id, modelID: "disabled", expectedRevision: document.revision); XCTFail("Selected unauthorized model") } catch {}
    }
    func testAllProtocolsRejectDisabledModelsBeforeSerialization() throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            var profile = ProviderProfile(name: "Vendor", protocolKind: kind, baseURL: "https://example.test", model: "first")
            profile.modelIDs = ["first", "second"]
            var input = LLMRequest(system: "Fixture", messages: [.init(role: .user, content: "{}")]); input.modelID = "second"
            let result = try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false)
            if kind == .geminiGenerateContent { XCTAssertTrue(result.url.path.contains("models/second:")) }
            else { XCTAssertEqual((try JSONSerialization.jsonObject(with: result.body) as? [String: Any])?["model"] as? String, "second") }
            input.modelID = "disabled"
            XCTAssertThrowsError(try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false))
        }
    }
    func testManualContextReservesInputAndNativeDefaultOmitsOutputLimit() throws {
        var profile = ProviderProfile(name: "Vendor", protocolKind: .openaiCompatible, baseURL: "https://example.test/v1", model: "first")
        var input = LLMRequest(system: "Fixture", messages: [.init(role: .user, content: "{}")]); input.nativeOutputLimit = true
        let automatic = try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false)
        XCTAssertNil((try JSONSerialization.jsonObject(with: automatic.body) as? [String: Any])?["max_tokens"])
        profile.limits = .init(tokenBudget: 4096, nativeOutputLimit: false); profile.limits.contextWindow = 4096
        let result = try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: false)
        let tokens = try XCTUnwrap((try JSONSerialization.jsonObject(with: result.body) as? [String: Any])?["max_tokens"] as? Int)
        XCTAssertGreaterThan(tokens, 0); XCTAssertLessThan(tokens, 4096)
        profile.limits.contextWindow = 128
        XCTAssertThrowsError(try profile.validate())
    }
    func testModelListsRejectDuplicatesInjectionAndUnknownVisionModels() throws {
        var profile = ProviderProfile(name: "Vendor", protocolKind: .openaiCompatible, baseURL: "https://example.test/v1", model: "one")
        for ids in [["one", "one"], ["two"], ["one", "x\nheader"], [], Array(repeating: "one", count: 65)] {
            profile.modelIDs = ids; XCTAssertThrowsError(try profile.validate())
        }
        profile.modelIDs = ["one"]; profile.visionModelIDs = ["other"]
        XCTAssertThrowsError(try profile.validate())
        profile.visionModelIDs = ["one"]; XCTAssertNoThrow(try profile.validate())
    }
}
