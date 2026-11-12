import XCTest
@testable import WallpaperMachine

@MainActor final class CreatorConnectionIsolationTests: XCTestCase {
    func testCloudAndLocalSaveAndDeleteInSeparateCredentialNamespaces() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let cloud = c.profile
        XCTAssertEqual(cloud.credentialNamespace, .cloud)
        var input = CreatorProviderCatalog.entry("lmstudio")!.profile()
        input.model = "local-model"; input.usesCredential = true
        var document = try await c.settings.settings()
        document = try await c.settings.saveProfile(input, expectedRevision: document.revision)
        let local = try XCTUnwrap(document.profiles.first { $0.id == input.id })
        XCTAssertEqual(local.credentialNamespace, .local)
        XCTAssertNotEqual(ProviderCredentialStore.service(for: cloud), ProviderCredentialStore.service(for: local))
        try await c.credentials.bind("local-fixture-key", to: local, settings: c.settings)
        let cloudService = ProviderCredentialStore.service(for: cloud), localService = ProviderCredentialStore.service(for: local)
        XCTAssertNotNil(c.memory.data(service: cloudService, account: cloud.id.uuidString.lowercased()))
        XCTAssertNotNil(c.memory.data(service: localService, account: local.id.uuidString.lowercased()))
        XCTAssertNil(c.memory.data(service: cloudService, account: local.id.uuidString.lowercased()))
        XCTAssertNil(c.memory.data(service: localService, account: cloud.id.uuidString.lowercased()))
        for (profile, expectedKey) in [(cloud, LLMTestFixtures.key), (local, "local-fixture-key")] {
            let descriptor = try LLMRequestDescriptor.make(profile: profile,
                input: .init(system: "Fixture", messages: [.init(role: .user, content: "{}")]), jsonMode: false)
            let grant = try await c.credentials.resolve(for: profile, settings: c.settings)
            XCTAssertEqual(try grant.request(descriptor).value(forHTTPHeaderField: "Authorization"), "Bearer " + expectedKey)
        }
        let reopened = try await CreatorSettingsStore(url: c.settings.url).settings()
        XCTAssertEqual(reopened.profiles.first { $0.id == cloud.id }, cloud)
        XCTAssertEqual(reopened.profiles.first { $0.id == local.id }, local)
        try await c.credentials.remove(for: local, settings: c.settings)
        _ = try await c.settings.removeProfile(local.id, expectedRevision: reopened.revision)
        XCTAssertNotNil(c.memory.data(service: cloudService, account: cloud.id.uuidString.lowercased()))
        XCTAssertNil(c.memory.data(service: localService, account: local.id.uuidString.lowercased()))
        let persisted = try String(contentsOf: c.settings.url, encoding: .utf8)
        XCTAssertFalse(persisted.contains(LLMTestFixtures.key)); XCTAssertFalse(persisted.contains("local-fixture-key"))
    }

    func testSavedIdentityCannotSwitchKindOrDowngradeItsCredentialNamespace() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let saved = try await c.settings.settings()
        var wrongKind = c.profile; wrongKind.localMode = true; wrongKind.credentialNamespace = .local
        var downgraded = c.profile; downgraded.credentialNamespace = nil
        for draft in [wrongKind, downgraded] {
            do { _ = try await c.settings.saveProfile(draft, expectedRevision: saved.revision); XCTFail("Changed storage scope of an existing identity") }
            catch {}
        }
        let after = try await c.settings.settings()
        XCTAssertEqual(after, saved)
        _ = try await c.credentials.resolve(for: c.profile, settings: c.settings)
    }

    func testLegacyRecordKeepsItsExactDigestAndKeychainNamespace() async throws {
        let c = try await LLMTestContext(bind: false); defer { c.cleanup() }
        var legacy = c.profile; legacy.credentialNamespace = nil
        var document = try await c.settings.settings(); document.profiles = [legacy]
        let data = try CreatorPersistence.record(document)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("credentialNamespace"))
        try CreatorPersistence.atomicWrite(data, to: c.settings.url)
        let reopened = try await c.settings.settings()
        XCTAssertEqual(try CreatorPersistence.record(reopened), data)
        XCTAssertEqual(ProviderCredentialStore.service(for: legacy), ProviderCredentialStore.service)
        try await c.credentials.bind(LLMTestFixtures.key, to: legacy, settings: c.settings)
        let storeAfterRestart = ProviderCredentialStore(calls: c.memory)
        _ = try await storeAfterRestart.resolve(for: legacy, settings: c.settings)
        XCTAssertEqual(c.memory.readCount, 1)
        XCTAssertNotNil(c.memory.data(service: ProviderCredentialStore.service, account: legacy.id.uuidString.lowercased()))
    }

    func testNewLocalNoKeyMakesNoKeychainReadOrEmptyRecord() async throws {
        let c = try await LLMTestContext(bind: false); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        var input = CreatorProviderCatalog.entry("lmstudio")!.profile(); input.model = "local-model"
        let current = try await c.settings.settings()
        let saved = try await workspace.saveProfile(input, key: "", expectedRevision: current.revision)
        let local = try XCTUnwrap(saved.profiles.first { $0.id == input.id })
        _ = try await c.credentials.resolve(for: local, settings: c.settings)
        XCTAssertEqual(c.memory.readCount, 0)
        XCTAssertNil(c.memory.data(service: ProviderCredentialStore.service(for: local), account: local.id.uuidString.lowercased()))
    }

    func testSavingAnUnchangedLocalConnectionWithBlankInputKeepsItsSavedKey() async throws {
        let c = try await LLMTestContext(bind: false); defer { c.cleanup() }
        let workspace = CreatorWorkspaceTests.workspace(c)
        var input = CreatorProviderCatalog.entry("lmstudio")!.profile(); input.model = "local-model"
        let current = try await c.settings.settings()
        let first = try await workspace.saveProfile(input, key: "local-fixture-key", expectedRevision: current.revision)
        let local = try XCTUnwrap(first.profiles.first { $0.id == input.id })
        let second = try await workspace.saveProfile(local, key: "", expectedRevision: first.revision)
        XCTAssertEqual(second, first)
        XCTAssertEqual(c.memory.readCount, 0)
        let descriptor = try LLMRequestDescriptor.make(profile: local,
            input: .init(system: "Fixture", messages: [.init(role: .user, content: "{}")]), jsonMode: false)
        let grant = try await ProviderCredentialStore(calls: c.memory).resolve(for: local, settings: c.settings)
        XCTAssertEqual(try grant.request(descriptor).value(forHTTPHeaderField: "Authorization"), "Bearer local-fixture-key")
    }
}
