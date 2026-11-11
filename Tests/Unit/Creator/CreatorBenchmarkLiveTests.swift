import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorBenchmarkLiveTests: XCTestCase {
    func testTenPromptsThreeRounds() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CREATOR_BENCHMARK"] == "1" else { throw XCTSkip("30-case model benchmark requires explicit opt-in; no live request in routine gates.") }
        let timing = try CreatorBenchmarkHarness.LiveTiming(env)
        executionTimeAllowance = timing.executionAllowance
        var samples: [CreatorBenchmarkHarness.Sample] = []
        var configuration: [String: String] = [:]
        defer {
            try? CreatorBenchmarkHarness.attach(CreatorBenchmarkHarness.report(mode: "live", configuration: configuration, samples: samples),
                name: "Creator benchmark live report", to: self)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            guard let kind = env["CREATOR_LIVE_PROTOCOL"].flatMap(ProviderProfile.ProtocolKind.init(rawValue:)),
                  let endpoint = env["CREATOR_LIVE_ENDPOINT"], let model = env["CREATOR_LIVE_MODEL"] else { throw CreatorGenerationFailure.invalidRequest }
            var input = ProviderProfile(name: "Temporary benchmark", protocolKind: kind, baseURL: endpoint, model: model)
            input.localMode = env["CREATOR_LIVE_LOCAL_MODE"] == "1"
            input.limits = .init(requestBudget: 3, tokenBudget: 6144)
            if kind == .openaiCompatible { input.capabilities.jsonMode = try CreatorLiveSmokeTests.jsonMode(env) }
            try input.validate()
            let settings = CreatorSettingsStore(url: root.appendingPathComponent("settings.json"))
            let saved = try await settings.saveProfile(input, expectedRevision: 0)
            let profile = try XCTUnwrap(saved.profiles.first)
            let key = try await CreatorLiveSmokeTests.temporaryKey(env)
            let credentials = ProviderCredentialStore(calls: MemoryKeychain())
            if key.isEmpty {
                guard profile.allowsEmptyKey else { throw CreatorGenerationFailure.invalidRequest }
            } else { try await credentials.bind(key, to: profile, settings: settings) }
            configuration = ["protocol": kind.rawValue, "model": CreatorConversationText.sanitize(model.replacingOccurrences(of: key.isEmpty ? "\u{0000}" : key, with: "[redacted]")),
                "maxRequestsPerCase": "3", "maxOutputTokensPerRequest": "2048", "maxRequestsTotal": "90",
                "jsonMode": input.capabilities.jsonMode?.rawValue ?? "protocolNative",
                "executionAllowanceSeconds": String(timing.executionAllowance), "requestTimeoutSeconds": String(timing.requestTimeout)]
            let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
            let registry = CreatorRuntimeRegistry(url: root.appendingPathComponent("registry.json"))
            let publisher = CreatorPublisher(root: root.appendingPathComponent("Publication"), library: root.appendingPathComponent("Library"), registry: registry)
            let provider = LLMProvider(settings: settings, credentials: credentials, transport: .init(limits: .init(timeout: timing.requestTimeout)))
            for round in 1...3 {
                for prompt in CreatorBenchmarkHarness.prompts {
                    let sample = try await CreatorBenchmarkHarness.runCase(prompt, round: round, store: store, profile: profile,
                        settings: settings, provider: provider, publisher: publisher)
                    samples.append(sample)
                    CreatorBenchmarkHarness.emitProgress(sample, index: samples.count)
                    // Authentication/configuration rejection cannot be repaired by spending 29 more calls.
                    if ["unauthorized", "invalidRequest", "staleInput"].contains(sample.failure ?? "") { throw CreatorGenerationFailure.invalidRequest }
                }
            }
            XCTAssertEqual(samples.count, 30)
            XCTAssertGreaterThanOrEqual(CreatorBenchmarkHarness.Metrics(samples).repairedPassRate, 0.8,
                "PRD runnable target missed; see structured report. This does not score visual preferences.")
        } catch {
            throw CreatorGenerationFailure.sanitized(error) // Never print an endpoint, raw response or key.
        }
    }
}
