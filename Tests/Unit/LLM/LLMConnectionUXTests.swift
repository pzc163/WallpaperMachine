import XCTest
@testable import WallpaperMachine

@MainActor final class LLMConnectionUXTests: XCTestCase {
    func testEmptyLocalCredentialsNeverTouchKeychainAndRemoteReadsOncePerSession() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        XCTAssertEqual(c.memory.readCount, 0)
        for _ in 0..<5 { _ = try await c.credentials.resolve(for: c.profile, settings: c.settings) }
        XCTAssertEqual(c.memory.readCount, 1)
        try await c.credentials.bind("replacement-fixture", to: c.profile, settings: c.settings)
        _ = try await c.credentials.resolve(for: c.profile, settings: c.settings)
        XCTAssertEqual(c.memory.readCount, 2)
        var local = LLMTestFixtures.profile(); local.localMode = true; local.baseURL = "http://192.168.1.20:1234/v1"
        var document = try await c.settings.settings()
        document = try await c.settings.saveProfile(local, expectedRevision: document.revision)
        let saved = try XCTUnwrap(document.profiles.last)
        try await c.credentials.bind("", to: saved, settings: c.settings)
        for _ in 0..<5 { _ = try await c.credentials.resolve(for: saved, settings: c.settings) }
        XCTAssertEqual(c.memory.readCount, 2)
        XCTAssertNil(c.memory.data(service: ProviderCredentialStore.service, account: saved.id.uuidString.lowercased()))
        try await c.credentials.remove(for: saved, settings: c.settings)
        XCTAssertEqual(c.memory.readCount, 2)
    }
    func testLocalModelDiscoveryUsesGETNoKeychainAndRejectsUntrustedTargets() async throws {
        var profile = LLMTestFixtures.profile(); profile.localMode = true; profile.baseURL = "http://192.168.1.20:1234/v1"; profile.model = ""
        let url = URL(string: profile.baseURL + "/models")!
        let route = LLMMockURLProtocol.Route([.init(headers: ["Content-Type": "application/json"], chunks: [Data(#"{"data":[{"id":"z"},{"id":"a"},{"id":"z"}]}"#.utf8)])])
        LLMMockURLProtocol.register(route, at: url); defer { LLMMockURLProtocol.remove(url) }
        let catalog = LLMModelCatalog(transport: .init(configuration: LLMMockURLProtocol.configuration()))
        let result = try await catalog.fetch(profile: profile, key: "")
        XCTAssertEqual(result, ["a", "z"]); XCTAssertEqual(route.requests.count, 1)
        XCTAssertEqual(route.requests[0].httpMethod, "GET"); XCTAssertNil(route.requests[0].value(forHTTPHeaderField: "Authorization"))
        profile.baseURL = "http://8.8.8.8/v1"
        do { _ = try await catalog.fetch(profile: profile, key: ""); XCTFail("Allowed public HTTP") } catch {}
        XCTAssertEqual(route.requests.count, 1)
    }
    func testBundledATSDeclaresNarrowIPRangesWithoutGlobalNativeBypass() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        let ranges = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
        XCTAssertEqual(Set(ranges.keys), ["127.0.0.1", "::1", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fe80::/10", "fc00::/7"])
        for value in ranges.values { XCTAssertEqual(value["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true) }
    }
}
