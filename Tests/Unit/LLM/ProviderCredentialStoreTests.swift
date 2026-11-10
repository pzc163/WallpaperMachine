import XCTest
@testable import WallpaperMachine

@MainActor
final class ProviderCredentialStoreTests: XCTestCase {
    func testAllThreeAuthenticationHeadersAreNativeAndNeverInURLOrBody() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let context = try await LLMTestContext(kind: kind)
            defer { context.cleanup() }
            let grant = try await context.credentials.resolve(for: context.profile, settings: context.settings)
            let descriptor = try LLMRequestDescriptor.make(profile: context.profile, input: LLMTestFixtures.input, jsonMode: true)
            let request = try grant.request(descriptor)
            let key = LLMTestFixtures.key
            switch kind {
            case .openaiCompatible:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            case .anthropicMessages:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            case .geminiGenerateContent:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
                XCTAssertEqual(request.url?.query, "alt=sse")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            }
            XCTAssertFalse(String(describing: grant).contains(key))
            XCTAssertFalse(String(reflecting: grant).contains(key))
            XCTAssertTrue(Mirror(reflecting: grant).children.isEmpty)
            XCTAssertFalse(request.url!.absoluteString.contains(key))
            XCTAssertFalse(String(decoding: descriptor.body, as: UTF8.self).contains(key))
            XCTAssertFalse(String(decoding: try Data(contentsOf: context.settings.url), as: UTF8.self).contains(key))
        }
    }
    func testSameHostProfilesHaveIndependentKeysAndCopyDoesNotInheritBinding() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        var second = LLMTestFixtures.profile(); second.baseURL = c.profile.baseURL
        var saved = try await c.settings.settings()
        saved = try await c.settings.saveProfile(second, expectedRevision: saved.revision)
        let other = saved.profiles[1]
        do { _ = try await c.credentials.resolve(for: other, settings: c.settings); XCTFail("Inherited another profile's key") } catch {}
        try await c.credentials.bind("other-fixture-key", to: other, settings: c.settings)
        for (profile, key) in [(c.profile, LLMTestFixtures.key), (other, "other-fixture-key")] {
            let grant = try await c.credentials.resolve(for: profile, settings: c.settings)
            let descriptor = try LLMRequestDescriptor.make(profile: profile, input: LLMTestFixtures.input, jsonMode: true)
            XCTAssertEqual(try grant.request(descriptor).value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        }
    }
    func testHostPortModelAndConfigurationChangesRequireExplicitRebinding() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        var document = try await c.settings.settings()
        var current = c.profile
        for address in ["https://changed.invalid", "https://changed.invalid:8443", "https://changed.invalid:8443/v2"] {
            current.baseURL = address
            document = try await c.settings.saveProfile(current, expectedRevision: document.revision)
            current = document.profiles[0]
            do { _ = try await c.credentials.resolve(for: current, settings: c.settings); XCTFail("Automatically reused old credentials") }
            catch { XCTAssertEqual(error as? LLMFailure, .credentialsUnavailable) }
            try await c.credentials.bind(LLMTestFixtures.key, to: current, settings: c.settings)
        }
        current.model = "changed-model"
        document = try await c.settings.saveProfile(current, expectedRevision: document.revision)
        do { _ = try await c.credentials.resolve(for: document.profiles[0], settings: c.settings); XCTFail("Reused stale configuration") } catch {}
    }
    func testDeleteAndRecreateStableIDDoesNotReviveKeychainBinding() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        var saved = try await c.settings.settings()
        saved = try await c.settings.removeProfile(c.profile.id, expectedRevision: saved.revision)
        var replacement = LLMTestFixtures.profile(); replacement.id = c.profile.id; replacement.baseURL = c.profile.baseURL
        saved = try await c.settings.saveProfile(replacement, expectedRevision: saved.revision)
        do { _ = try await c.credentials.resolve(for: saved.profiles[0], settings: c.settings); XCTFail("Revived an old key") }
        catch { XCTAssertEqual(error as? LLMFailure, .credentialsUnavailable) }
        XCTAssertNotNil(c.memory.data(service: ProviderCredentialStore.service, account: c.profile.id.uuidString.lowercased()))
    }
    func testOnlyExplicitExactLocalOpenAIAllowsMissingKey() async throws {
        let c = try await LLMTestContext(bind: false); defer { c.cleanup() }
        do { _ = try await c.credentials.resolve(for: c.profile, settings: c.settings); XCTFail("Allowed a remote empty key") } catch {}
        var saved = try await c.settings.settings()
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            var local = LLMTestFixtures.profile(); local.baseURL = "http://\(host):8080/v1"; local.localMode = true
            saved = try await c.settings.saveProfile(local, expectedRevision: saved.revision)
            let profile = try XCTUnwrap(saved.profiles.last)
            let grant = try await c.credentials.resolve(for: profile, settings: c.settings)
            let request = try grant.request(LLMRequestDescriptor.make(profile: profile, input: LLMTestFixtures.input, jsonMode: true))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }
    func testKeychainFailureAndMalformedKeysDoNotExposeTheirText() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        for key in ["", "bad\nheader", " leading", String(repeating: "x", count: 4097)] {
            do { try await c.credentials.bind(key, to: c.profile, settings: c.settings); XCTFail("Accepted invalid key") }
            catch { XCTAssertEqual(error as? LLMFailure, .credentialsUnavailable) }
        }
        c.memory.refuseUpdates(with: -25293)
        do { try await c.credentials.bind("another-fixture-key", to: c.profile, settings: c.settings); XCTFail("Ignored keychain error") }
        catch { XCTAssertEqual(error as? LLMFailure, .credentialsUnavailable) }
        let grant = try await c.credentials.resolve(for: c.profile, settings: c.settings)
        let request = try grant.request(LLMRequestDescriptor.make(profile: c.profile, input: LLMTestFixtures.input, jsonMode: true))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + LLMTestFixtures.key)
    }
    func testGrantCannotAuthorizeAChangedOriginOrCredentialQuery() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let grant = try await c.credentials.resolve(for: c.profile, settings: c.settings)
        for address in ["https://other.invalid/v1/chat/completions", c.url.absoluteString + "?key=fixture"] {
            let descriptor = LLMRequestDescriptor(url: URL(string: address)!, headers: [:], body: Data("{}".utf8), authentication: .bearer)
            XCTAssertThrowsError(try grant.request(descriptor))
        }
    }
    func testOldMetadataWithoutNewCapabilityStillReencodesExactly() throws {
        let original = LLMTestFixtures.profile()
        let bytes = try CreatorPersistence.record(original)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("jsonMode"))
        let restored = try CreatorPersistence.decode(ProviderProfile.self, from: bytes)
        XCTAssertNil(restored.capabilities.jsonMode)
        XCTAssertEqual(try CreatorPersistence.record(restored), bytes)
    }
}
