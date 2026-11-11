import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorBenchmarkTests: XCTestCase {
    func testTenPromptsThreeRoundsUseRealValidationAndDeterministicMockStatistics() async throws {
        let c = try await LLMTestContext(tokens: 6144); defer { c.cleanup() }
        let registry = CreatorRuntimeRegistry(url: c.root.appendingPathComponent("registry.json"))
        let publisher = CreatorPublisher(root: c.root.appendingPathComponent("publication"), library: c.root.appendingPathComponent("Library"), registry: registry)
        var samples: [CreatorBenchmarkHarness.Sample] = []
        for round in 1...3 {
            for (index, prompt) in CreatorBenchmarkHarness.prompts.enumerated() {
                let repairs = index < 6 ? 0 : index < 8 ? 1 : 2
                let good = try LLMTestFixtures.openAI(CreatorGenerationFixtures.output(prompt.template), usage: index == 0 ? nil : ["prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20])
                let bad = try LLMTestFixtures.openAI("{invalid")
                let replies = Array(repeating: LLMMockURLProtocol.Reply(chunks: [bad]), count: repairs)
                    + [.init(chunks: [index == 9 ? bad : good])]
                let route = LLMMockURLProtocol.Route(replies)
                LLMMockURLProtocol.register(route, at: c.url)
                let sample = try await CreatorBenchmarkHarness.runCase(prompt, round: round, store: c.store, profile: c.profile,
                    settings: c.settings, provider: c.provider, publisher: publisher)
                samples.append(sample)
                CreatorBenchmarkHarness.emitProgress(sample, index: samples.count)
                XCTAssertEqual(sample.requests, repairs + 1)
                XCTAssertEqual(route.requests.count, sample.requests)
                XCTAssertEqual(sample.passed, index != 9)
            }
        }
        let report = CreatorBenchmarkHarness.report(mode: "deterministicMock", samples: samples)
        XCTAssertEqual(report.metrics.samples, 30)
        XCTAssertEqual(report.metrics.firstPassRate, 0.6, accuracy: 0.0001)
        XCTAssertEqual(report.metrics.repairedPassRate, 0.9, accuracy: 0.0001)
        XCTAssertEqual(report.metrics.requests, 48)
        // 21 syntactically malformed replies fail inside the codec before a complete
        // response is returned; their usage remains unknown, plus three missing-usage successes.
        XCTAssertEqual(report.metrics.unknownUsageAttempts, 24)
        XCTAssertEqual(report.metrics.knownTotalTokens, 480)
        XCTAssertFalse(report.targetEstablished, "Mock success cannot establish real model quality")
        XCTAssertEqual(report.metrics.reservedOutputTokens, 48 * 2048)
        XCTAssertEqual(report.metrics.latency.count, 30)
        XCTAssertEqual(report.metrics.successfulLatency.count, 27)
        try CreatorBenchmarkHarness.attach(report, name: "Creator benchmark mock report", to: self)
        // Scan all persisted artifacts, not merely conversation.json; HTTP request fixtures
        // intentionally contain authorization but are never included in this evidence.
        let forbidden = [LLMTestFixtures.key, "private thought", "Bearer "]
        try CreatorBenchmarkHarness.assertNoSecrets(in: c.root, forbidden: forbidden)
        let evidence = try CreatorPersistence.encode(report)
        for value in forbidden {
            XCTAssertNil(evidence.range(of: Data(value.utf8)))
            XCTAssertFalse(c.diagnostics.lines.joined().contains(value))
        }
    }
    func testLiveJSONModeDefaultsToAutomaticAndRejectsUnknownValuesWithoutEcho() throws {
        XCTAssertEqual(try CreatorLiveSmokeTests.jsonMode([:]), .automatic)
        for mode in [ProviderProfile.Capabilities.JSONMode.automatic, .required, .schema, .disabled] {
            XCTAssertEqual(try CreatorLiveSmokeTests.jsonMode(["CREATOR_LIVE_JSON_MODE": mode.rawValue]), mode)
        }
        for value in ["", "json_schema", "secret-key", "REQUIRED"] {
            XCTAssertThrowsError(try CreatorLiveSmokeTests.jsonMode(["CREATOR_LIVE_JSON_MODE": value])) {
                XCTAssertEqual($0 as? CreatorGenerationFailure, .invalidRequest)
                XCTAssertFalse(String(describing: $0).contains("secret-key"))
            }
        }
    }

    func testLiveTimingDefaultsOverridesAndTransportBoundaries() throws {
        let defaults = try CreatorBenchmarkHarness.LiveTiming([:])
        XCTAssertEqual(defaults.executionAllowance, 3600); XCTAssertEqual(defaults.requestTimeout, 90)
        for (allowance, timeout) in [(600.0, 5.0), (7200.5, 120.0), (86_400.0, 600.0)] {
            let timing = try CreatorBenchmarkHarness.LiveTiming([
                "CREATOR_BENCHMARK_ALLOWANCE": String(allowance), "CREATOR_LIVE_TIMEOUT": String(timeout)])
            XCTAssertEqual(timing.executionAllowance, allowance); XCTAssertEqual(timing.requestTimeout, timeout)
            XCTAssertNoThrow(try LLMStreamTransport.Limits(timeout: timing.requestTimeout).validate())
        }
        XCTAssertThrowsError(try LLMStreamTransport.Limits(timeout: 601).validate())
        XCTAssertEqual(LLMStreamTransport.Limits().timeout, 300)
        XCTAssertEqual(LLMStreamTransport.Limits().firstResponseTimeout, 25)
        XCTAssertEqual(LLMStreamTransport.Limits().idleTimeout, 90)
    }
    func testLiveTimingRejectsNonFiniteMalformedAndOutOfRangeValues() {
        for field in ["CREATOR_BENCHMARK_ALLOWANCE", "CREATOR_LIVE_TIMEOUT"] {
            let invalid = ["", "nan", "inf", "-1", "0", "secret-value", field == "CREATOR_LIVE_TIMEOUT" ? "601" : "86401",
                           field == "CREATOR_LIVE_TIMEOUT" ? "4.9" : "599.9"]
            for value in invalid {
                XCTAssertThrowsError(try CreatorBenchmarkHarness.LiveTiming([field: value])) { error in
                    XCTAssertEqual(error as? CreatorGenerationFailure, .invalidRequest)
                }
            }
        }
    }
    func testProgressNeverIncludesModelFieldsOrArbitraryFailureText() {
        for failure in [nil, "timeout", "https://secret.invalid/ private output Bearer secret-key\n"] as [String?] {
            let sample = CreatorBenchmarkHarness.Sample(promptID: "private output", round: 2, passed: failure == nil,
                requests: 3, elapsedSeconds: 12.345, usage: [], reservedOutputTokens: 6144,
                failure: failure, generatedTemplate: "secret-key")
            let safeFailure = failure == nil ? "none" : failure == "timeout" ? "timeout" : "invalidRequest"
            let line = CreatorBenchmarkHarness.progressLine(sample, index: 12)
            XCTAssertEqual(line, "Creator benchmark 12/30 round=2 passed=\(failure == nil) attemptCount=3 elapsedSeconds=12.345 failure=\(safeFailure)")
            for secret in ["https://", "private output", "secret-key", "Bearer", "\n"] { XCTAssertFalse(line.contains(secret)) }
        }
    }
    func testURLSessionIdleTimeoutRemainsIndependentOfConfiguredTotalForEveryProtocol() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            for timeout in [90.0, 600.0] {
                let c = try await LLMTestContext(kind: kind, timeout: timeout); defer { c.cleanup() }
                _ = try await c.run()
                XCTAssertEqual(c.route.requests.count, 1)
                XCTAssertEqual(try XCTUnwrap(c.route.requests.first).timeoutInterval, 90, "URLSession request timeout is idle, not total; transport independently enforces total")
            }
        }
    }
    func testPercentilesMissingUsageAndFailuresAreNotHiddenBySuccessOnlyDenominator() {
        let samples = (1...10).map { index in
            CreatorBenchmarkHarness.Sample(promptID: "G01", round: index, passed: index <= 7, requests: 1,
                elapsedSeconds: Double(index), usage: [index == 1 ? .init(inputTokens: 4) : nil], reservedOutputTokens: 2048,
                failure: index <= 7 ? nil : "timeout")
        }
        let metrics = CreatorBenchmarkHarness.Metrics(samples)
        XCTAssertEqual(metrics.repairedPassRate, 0.7)
        XCTAssertFalse(metrics.meetsRunnableTarget)
        XCTAssertEqual(metrics.latency.p50, 5); XCTAssertEqual(metrics.latency.p95, 10)
        XCTAssertEqual(metrics.unknownUsageAttempts, 9); XCTAssertEqual(metrics.incompleteUsageAttempts, 10)
        XCTAssertEqual(metrics.knownInputTokens, 4)
        XCTAssertNil(CreatorBenchmarkHarness.Metrics([]).latency.p50)
        XCTAssertEqual(Set(CreatorBenchmarkHarness.prompts.map(\.id)).count, 10)
        XCTAssertEqual(Set(CreatorBenchmarkHarness.prompts.map(\.template)), ["stars-v2", "gradient-v2", "clock-v2"])
    }
}
