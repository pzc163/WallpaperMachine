import XCTest
@testable import WallpaperMachine

final class ProviderProfileTests: XCTestCase {
    private func profile(_ url: String, kind: ProviderProfile.ProtocolKind = .openaiCompatible,
                         local: Bool = false) -> ProviderProfile {
        ProviderProfile(name: "Test", protocolKind: kind, baseURL: url, model: "test-model", localMode: local)
    }

    func testThreeProtocolsRoundTripWithoutCredentials() throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let value = profile("https://api.example.test/v1", kind: kind)
            try value.validate()
            let data = try CreatorPersistence.record(value)
            XCTAssertEqual(try CreatorPersistence.decode(ProviderProfile.self, from: data), value)
            XCTAssertEqual(try value.origin(), .init(scheme: "https", host: "api.example.test", port: 443))
        }
    }

    func testJSONModesRoundTripAndSchemaRemainsOpenAIOnly() throws {
        for mode in [ProviderProfile.Capabilities.JSONMode.automatic, .required, .schema, .disabled] {
            var value = profile("https://fixture.invalid")
            value.capabilities.jsonMode = mode
            try value.validate()
            XCTAssertEqual(try CreatorPersistence.decode(ProviderProfile.self, from: CreatorPersistence.record(value)), value)
            for kind in [ProviderProfile.ProtocolKind.anthropicMessages, .geminiGenerateContent] {
                value.protocolKind = kind
                XCTAssertThrowsError(try value.validate())
            }
        }
        let legacy = profile("https://fixture.invalid")
        let bytes = try CreatorPersistence.record(legacy)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("jsonMode"))
        XCTAssertEqual(try CreatorPersistence.record(CreatorPersistence.decode(ProviderProfile.self, from: bytes)), bytes)
    }

    func testHTTPRequiresExplicitLocalOpenAIAndExactHost() throws {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "[::1]", "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.1.1", "[fc00::1]", "[fdff::1]", "[fe80::1]", "[fe80::1%25en0]", "[febf::1]", "studio.local", "Studio.LOCAL"] {
            try profile("http://\(host):8080/v1", local: true).validate()
            try profile("https://\(host)/v1", local: true).validate()
            XCTAssertThrowsError(try profile("http://\(host)/v1").validate())
            for kind in [ProviderProfile.ProtocolKind.anthropicMessages, .geminiGenerateContent] {
                XCTAssertThrowsError(try profile("http://\(host)/v1", kind: kind, local: true).validate())
                XCTAssertThrowsError(try profile("https://\(host)/v1", kind: kind, local: true).validate())
            }
        }
        for host in ["127.0.0.2", "127.1", "2130706433", "0x7f000001", "0.0.0.0", "172.15.255.255", "172.32.0.1", "192.169.0.1", "100.64.0.1", "169.254.1.1", "8.8.8.8", "010.0.0.1", "10.0.0.256", "192.168.001.1", "[fec0::1]", "[fe80::1%25en0%25bad]", "[fc00::1%25en0]", "[fe7f::1]", "[2001:db8::1]", "[ff02::1]", "local", "-bad.local", "bad..local", "studio.local.example.test",
                     "localhost.example.test", "localhost.", "[::ffff:127.0.0.1]", "[0:0:0:0:0:0:0:1]", "%6cocalhost"] {
            XCTAssertThrowsError(try profile("http://\(host)/v1", local: true).validate(), host)
            XCTAssertThrowsError(try profile("https://\(host)/v1", local: true).validate(), host)
        }
        XCTAssertEqual(try profile("http://[::1]:8080", local: true).origin().host, "::1")
    }

    func testURLsRejectEmbeddedCredentialsQueriesAndAmbiguousTargets() {
        for url in ["https://name:secret@example.test", "https://@example.test", "https://example.test?key=test",
                    "https://example.test?api_key=test", "https://example.test?alt=sse", "https://example.test?",
                    "https://example.test#part", "https://example.test#", "file:///tmp/model", "ftp://example.test",
                    "https:///", "https://example.test:0", "https://example.test:65536", "https://example.test:bad",
                    " https://example.test", "https://example.test/has space", "https://example.test/%0a",
                    "https://example.test/\n", "https://%6cocalhost", "https://example.test/" + String(repeating: "a", count: 2048)] {
            XCTAssertThrowsError(try profile(url).validate(), url)
        }
    }

    func testOriginComparisonIncludesSchemeHostAndEffectivePort() throws {
        let first = try profile("https://API.example.test/v1").origin()
        XCTAssertEqual(first, try profile("https://api.example.test:443/other").origin())
        XCTAssertNotEqual(first, try profile("https://other.example.test/v1").origin())
        XCTAssertNotEqual(first, try profile("https://api.example.test:8443/v1").origin())
        XCTAssertNotEqual(try profile("https://localhost", local: true).origin(),
                          try profile("http://localhost", local: true).origin())
    }

    func testMetadataAndBudgetBoundsAreValidated() throws {
        XCTAssertEqual(ProviderProfile.Limits.tokenBudget(from: ""), 24_576)
        XCTAssertEqual(ProviderProfile.Limits.tokenBudget(from: " \n"), 24_576)
        XCTAssertEqual(ProviderProfile.Limits().outputTokensPerRequest, 8192)
        for invalid in ["-1", "0", "NaN", "1e5", "100001", "999999999999999999999999"] {
            XCTAssertNil(ProviderProfile.Limits.tokenBudget(from: invalid))
        }
        let original = profile("https://example.test/v1")
        for requests in [1, 3] { for tokens in [1, 100_000] {
            var value = original; value.limits = .init(requestBudget: requests, tokenBudget: tokens)
            try value.validate()
        } }
        for requests in [0, 4, Int.max] {
            var value = original; value.limits.requestBudget = requests
            XCTAssertThrowsError(try value.validate())
        }
        for tokens in [0, 100_001, Int.max] {
            var value = original; value.limits.tokenBudget = tokens
            XCTAssertThrowsError(try value.validate())
        }
        for name in ["", " \n", "name\u{0}", String(repeating: "a", count: 61)] {
            var value = original; value.name = name
            XCTAssertThrowsError(try value.validate())
        }
        for model in ["", "model name", "model\n", String(repeating: "a", count: 129)] {
            var value = original; value.model = model
            XCTAssertThrowsError(try value.validate())
        }
        var future = original; future.schemaVersion = 2
        XCTAssertThrowsError(try future.validate())
    }

    func testModelAndCapabilityRulesRemainProtocolSpecific() throws {
        var value = profile("https://example.test/v1")
        value.model = "org/local-model:tag"
        value.capabilities = .init(requestsUsage: false, filtersLeadingThinkBlock: true)
        try value.validate()
        for kind in [ProviderProfile.ProtocolKind.anthropicMessages, .geminiGenerateContent] {
            value.protocolKind = kind
            XCTAssertThrowsError(try value.validate())
        }
        value.capabilities = .init()
        for model in ["models/gemini", "a/b", "a?key=test", "a#fragment", "a%2fb", "模型"] {
            value.model = model
            XCTAssertThrowsError(try value.validate())
        }
        value.model = "gemini-test-2.0"
        try value.validate()
    }
}
