import XCTest
@testable import WallpaperMachine

@MainActor
final class LLMProviderTests: XCTestCase {
    private func failure<T>(_ operation: () async throws -> T) async -> LLMFailure? {
        do { _ = try await operation(); XCTFail("Unexpected provider success"); return nil }
        catch { return error as? LLMFailure }
    }
    func testThreeProtocolsUseSharedMockTransportAndLeaveNoExecutableRevision() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let c = try await LLMTestContext(kind: kind); defer { c.cleanup() }
            let data = try LLMTestFixtures.body(for: kind)
            c.route.replace([.init(chunks: stride(from: 0, to: data.count, by: 3).map { data.subdata(in: $0..<min($0 + 3, data.count)) })])
            let completion = try await c.run()
            XCTAssertEqual(completion.response.text, LLMTestFixtures.answer)
            XCTAssertEqual(completion.attempts, 1); XCTAssertEqual(completion.reservedOutputTokens, 64)
            XCTAssertEqual(completion.profile.configurationID, c.profile.configurationID)
            let project = try await c.store.project(c.ticket.projectID)
            XCTAssertTrue(project.revisionIDs.isEmpty)
            XCTAssertEqual(c.route.requests.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.jobURL(c.ticket.id).appendingPathComponent("partial.bin").path))
            XCTAssertFalse(c.diagnostics.lines.joined().contains(LLMTestFixtures.key))
            XCTAssertFalse(c.diagnostics.lines.joined().contains("private thought"))
        }
    }
    func test401DoesNotRetryAndFailureBodiesNeverReachLogsOrErrors() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(status: 401, chunks: [Data((LLMTestFixtures.key + " private thought").utf8)])])
        let result = await failure { try await c.run() }
        XCTAssertEqual(result, .unauthorized)
        XCTAssertEqual(c.route.requests.count, 1); XCTAssertTrue(c.diagnostics.delays.isEmpty)
        let job = try await c.store.job(c.ticket.id)
        XCTAssertEqual(job.state, .cancelled); XCTAssertEqual(job.attemptCount, 1)
        XCTAssertFalse(c.diagnostics.lines.joined().contains(LLMTestFixtures.key))
        XCTAssertFalse(String(reflecting: result).contains(LLMTestFixtures.key))
    }
    func testCompetingProviderCannotSendOrCancelTheOwnedJob() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(hold: true)])
        let first = Task { try await c.run() }
        try await c.waitForRequest()
        let other = LLMProvider(settings: c.settings, credentials: c.credentials,
            transport: .init(configuration: LLMMockURLProtocol.configuration()), log: { _ in })
        let result = await failure {
            try await other.generate(LLMTestFixtures.input, profileID: c.profile.id,
                configurationID: c.profile.configurationID, ticket: c.ticket, store: c.store)
        }
        XCTAssertEqual(result, .busy)
        let current = try await c.store.job(c.ticket.id)
        XCTAssertEqual(current.state, .generating)
        XCTAssertEqual(current.attemptCount, 1)
        XCTAssertEqual(c.route.requests.count, 1)
        first.cancel()
        let cancelled = await failure { try await first.value }
        XCTAssertEqual(cancelled, .cancelled)
    }
    func testCredentialReplacementAndRemovalCancelExistingFlight() async throws {
        for remove in [false, true] {
            let c = try await LLMTestContext(); defer { c.cleanup() }
            c.route.replace([.init(hold: true)])
            let task = Task { try await c.run() }
            try await c.waitForRequest()
            if remove { try await c.credentials.remove(for: c.profile, settings: c.settings) }
            else { try await c.credentials.bind("replacement-test-key", to: c.profile, settings: c.settings) }
            let result = await failure { try await task.value }
            XCTAssertEqual(result, .credentialsUnavailable)
            XCTAssertEqual(c.route.requests.count, 1)
            XCTAssertEqual(c.route.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + LLMTestFixtures.key)
            let job = try await c.store.job(c.ticket.id)
            XCTAssertEqual(job.state, .cancelled)
        }
    }
    func testInvalidInputAndInsufficientBudgetSendNoPackets() async throws {
        for oversizedInput in [false, true] {
            let c = try await LLMTestContext(); defer { c.cleanup() }
            let input = LLMRequest(system: oversizedInput ? String(repeating: "a", count: 16 * 1024) : "JSON",
                messages: [.init(role: .user, content: "x")], maxOutputTokens: oversizedInput ? 64 : 193)
            let result = await failure { try await c.run(input: input) }
            XCTAssertEqual(result, oversizedInput ? .invalidInput : .budgetExhausted)
            XCTAssertTrue(c.route.requests.isEmpty)
            let job = try await c.store.job(c.ticket.id)
            XCTAssertEqual(job.attemptCount, 0)
        }
    }
    func test429RetryAfterAnd503RetriesConsumePersistentBudgets() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(status: 429, headers: ["Retry-After": "2"]), .init(status: 503), .init(chunks: [try LLMTestFixtures.openAI()])])
        let result = try await c.run()
        XCTAssertEqual(result.attempts, 3); XCTAssertEqual(result.reservedOutputTokens, 192)
        XCTAssertEqual(c.route.requests.count, 3)
        XCTAssertEqual(c.diagnostics.delays, [2, 1])
        let job = try await c.store.job(c.ticket.id)
        XCTAssertEqual(job.attemptCount, 3); XCTAssertEqual(job.reservedOutputTokens, 192)
    }
    func testRequestAndOutputReservationsStopRetryAndSurviveAnotherProviderInstance() async throws {
        for (requests, tokens) in [(1, 192), (3, 64)] {
            let c = try await LLMTestContext(requests: requests, tokens: tokens); defer { c.cleanup() }
            c.route.replace([.init(status: 429, headers: ["Retry-After": "0"])])
            let result = await failure { try await c.run() }
            XCTAssertEqual(result, .rateLimited(retryAfter: 0))
            XCTAssertEqual(c.route.requests.count, 1)
            XCTAssertTrue(c.diagnostics.delays.isEmpty)
            let other = LLMProvider(settings: c.settings, credentials: c.credentials,
                transport: .init(configuration: LLMMockURLProtocol.configuration()), log: { _ in })
            let repeated = await failure {
                try await other.generate(LLMTestFixtures.input, profileID: c.profile.id, configurationID: c.profile.configurationID, ticket: c.ticket, store: c.store)
            }
            XCTAssertEqual(repeated, .invalidJob)
            XCTAssertEqual(c.route.requests.count, 1)
        }
    }
    func testExcessiveRetryAfterReturnsWithoutShorteningTheServersWait() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(status: 429, headers: ["Retry-After": "3600"])])
        let result = await failure { try await c.run() }
        XCTAssertEqual(result, .rateLimited(retryAfter: 3600))
        XCTAssertEqual(c.route.requests.count, 1); XCTAssertTrue(c.diagnostics.delays.isEmpty)
    }
    func testSchemaUnsupportedFallsBackOnlyInAutomaticModeAndWithinBudget() async throws {
        let input = try CreatorPromptBuilder.build(prompt: "星空", base: nil, maxOutputTokens: 64)
        let rejection = Data(#"{"error":{"param":"response_format.json_schema","code":"unsupported_value","message":"synthetic-secret"}}"#.utf8)
        for (mode, budget) in [(ProviderProfile.Capabilities.JSONMode.automatic, 3), (.automatic, 1), (.schema, 3), (.required, 3)] {
            let c = try await LLMTestContext(requests: budget, capabilities: .init(jsonMode: mode)); defer { c.cleanup() }
            c.route.replace([.init(status: 400, chunks: [rejection]), .init(chunks: [try LLMTestFixtures.openAI()])])
            if mode == .automatic && budget > 1 {
                let result = try await c.run(input: input)
                XCTAssertEqual(result.attempts, 2); XCTAssertEqual(result.reservedOutputTokens, 128)
            } else {
                let result = await failure { try await c.run(input: input) }
                XCTAssertEqual(result, .jsonModeUnsupported)
            }
            XCTAssertEqual(c.route.requests.count, mode == .automatic && budget > 1 ? 2 : 1)
            for (index, request) in c.route.requests.enumerated() {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
                let format = body["response_format"] as? [String: Any]
                if index == 0 { XCTAssertEqual(format?["type"] as? String, mode == .required ? "json_object" : "json_schema") }
                else { XCTAssertEqual(format?["type"] as? String, "json_object") }
            }
            XCTAssertFalse(c.diagnostics.lines.joined().contains("synthetic-secret"))
        }
        XCTAssertFalse(LLMHTTPPolicy.unsupportedJSONMode(Data(#"{"error":{"param":"model","code":"unsupported_value","message":"response_format"}}"#.utf8)))
        XCTAssertTrue(LLMHTTPPolicy.unsupportedJSONMode(Data(#"{"error":{"param":"response_format","code":"invalid_json_schema"}}"#.utf8)))
        XCTAssertTrue(LLMHTTPPolicy.unsupportedJSONMode(Data(#"{"error":{"message":"response_format is unsupported"}}"#.utf8)))
    }

    func testJSONModeFallbackIsExplicitNarrowAndBudgeted() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": ["param": "response_format", "code": "unsupported_parameter", "message": LLMTestFixtures.key]])
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(status: 400, chunks: [body]), .init(chunks: [try LLMTestFixtures.openAI()])])
        let result = try await c.run()
        XCTAssertEqual(result.attempts, 2); XCTAssertEqual(result.reservedOutputTokens, 128)
        let requests = c.route.requests
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertNotNil(first["response_format"]); XCTAssertNil(second["response_format"])
        XCTAssertNotNil(second["stream_options"])
        XCTAssertFalse(c.diagnostics.lines.joined().contains(LLMTestFixtures.key))
    }
    func testRequiredJSONModeAndUnrelated400NeverDowngrade() async throws {
        for required in [false, true] {
            var caps = ProviderProfile.Capabilities(); if required { caps.jsonMode = .required }
            let c = try await LLMTestContext(capabilities: caps); defer { c.cleanup() }
            let body = try JSONSerialization.data(withJSONObject: ["error": ["param": required ? "response_format" : "model", "code": "unsupported_parameter"]])
            c.route.replace([.init(status: 400, chunks: [body])])
            _ = await failure { try await c.run() }
            XCTAssertEqual(c.route.requests.count, 1)
        }
    }
    func testTimeoutAndTruncatedResponsesCancelJobWithoutRetry() async throws {
        for timeout in [false, true] {
            let c = try await LLMTestContext(timeout: timeout ? 0.1 : 3); defer { c.cleanup() }
            c.route.replace([.init(chunks: timeout ? [] : [try LLMTestFixtures.openAI(done: false)], hold: timeout)])
            let result = await failure { try await c.run() }
            XCTAssertEqual(result, timeout ? .timeout : .truncated)
            XCTAssertEqual(c.route.requests.count, 1)
            let job = try await c.store.job(c.ticket.id)
            XCTAssertEqual(job.state, .cancelled)
            let project = try await c.store.project(c.ticket.projectID)
            XCTAssertTrue(project.revisionIDs.isEmpty)
        }
    }
    func testTaskCancellationInterruptsHeldURLSessionAndCleansNativeJob() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(hold: true)])
        let task = Task { try await c.run() }
        try await c.waitForRequest(); task.cancel()
        let result = await failure { try await task.value }
        XCTAssertEqual(result, .cancelled)
        let deadline = ContinuousClock.now + .seconds(1)
        while c.route.stopCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(c.route.stopCount, 0)
        let job = try await c.store.job(c.ticket.id)
        XCTAssertEqual(job.state, .cancelled)
    }
    func testProfileChangeInAnotherStoreCancelsFlightAndNeverSendsToNewHost() async throws {
        for hostChange in [false, true] {
            let c = try await LLMTestContext(); defer { c.cleanup() }
            c.route.replace([.init(hold: true)])
            let task = Task { try await c.run() }
            try await c.waitForRequest()
            let other = CreatorSettingsStore(url: c.settings.url)
            let settings = try await other.settings()
            var changed = c.profile
            if hostChange { changed.baseURL = "https://new-host.invalid" } else { changed.model = "other-model" }
            let saved = try await other.saveProfile(changed, expectedRevision: settings.revision)
            XCTAssertNotEqual(saved.profiles[0].configurationID, c.profile.configurationID)
            let result = await failure { try await task.value }
            XCTAssertEqual(result, .staleProfile)
            XCTAssertEqual(c.route.requests.count, 1)
            XCTAssertEqual(c.route.requests[0].url, c.url)
        }
    }
    func testDeletedOrExternallyReplacedProfileCancelsFlight() async throws {
        for externallyChanged in [false, true] {
            let c = try await LLMTestContext(); defer { c.cleanup() }
            c.route.replace([.init(hold: true)])
            let task = Task { try await c.run() }; try await c.waitForRequest()
            var settings = try await c.settings.settings()
            if externallyChanged {
                settings.profiles[0].baseURL = "https://externally-changed.invalid"
                settings.profiles[0].configurationRevision += 1; settings.profiles[0].configurationID = UUID(); settings.revision += 1
                try CreatorPersistence.write(settings, to: c.settings.url)
            } else { _ = try await c.settings.removeProfile(c.profile.id, expectedRevision: settings.revision) }
            let result = await failure { try await task.value }
            XCTAssertEqual(result, .staleProfile)
            XCTAssertEqual(c.route.requests.count, 1)
        }
    }
    func testChangedProfileDuringBackoffPreventsNextPacket() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(status: 429, headers: ["Retry-After": "1"])])
        let settings = c.settings, profile = c.profile
        let provider = LLMProvider(settings: settings, credentials: c.credentials,
            transport: .init(configuration: LLMMockURLProtocol.configuration()), log: { _ in }, wait: { _ in
                let snapshot = try await settings.settings()
                var changed = profile; changed.baseURL = "https://changed-during-backoff.invalid"
                _ = try await settings.saveProfile(changed, expectedRevision: snapshot.revision)
            })
        let result = await failure {
            try await provider.generate(LLMTestFixtures.input, profileID: profile.id, configurationID: profile.configurationID, ticket: c.ticket, store: c.store)
        }
        XCTAssertEqual(result, .staleProfile)
        XCTAssertEqual(c.route.requests.count, 1)
    }
    func testSupersedingJobCancelsOldFlightWithoutCancellingItsReplacement() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        c.route.replace([.init(hold: true)])
        let task = Task { try await c.run() }; try await c.waitForRequest()
        let replacement = try await c.store.beginJob(projectID: c.ticket.projectID)
        let result = await failure { try await task.value }
        XCTAssertEqual(result, .cancelled)
        let job = try await c.store.job(replacement.id)
        XCTAssertEqual(job.state, .generating)
        let project = try await c.store.project(c.ticket.projectID)
        XCTAssertEqual(project.activeJobID, replacement.id)
        try await c.store.cancel(replacement)
    }
    func testStaleConfigurationAndMissingCredentialsSendNoPackets() async throws {
        for missingKey in [false, true] {
            let c = try await LLMTestContext(bind: !missingKey); defer { c.cleanup() }
            if !missingKey {
                var changed = c.profile; changed.baseURL = "https://changed-before-send.invalid"
                let settings = try await c.settings.settings()
                _ = try await c.settings.saveProfile(changed, expectedRevision: settings.revision)
            }
            let result = await failure { try await c.run() }
            XCTAssertEqual(result, missingKey ? .credentialsUnavailable : .staleProfile)
            XCTAssertTrue(c.route.requests.isEmpty)
            let job = try await c.store.job(c.ticket.id)
            XCTAssertEqual(job.attemptCount, 0)
        }
    }
    func testUnderlyingErrorsCannotLeakKeyURLOrResponseText() async throws {
        let c = try await LLMTestContext(); defer { c.cleanup() }
        let secret = LLMTestFixtures.key
        c.route.replace([.init(failure: URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: "https://\(secret).invalid"]))])
        let result = await failure { try await c.run() }
        XCTAssertEqual(result, .network)
        XCTAssertFalse(c.diagnostics.lines.joined().contains(secret))
        XCTAssertFalse(c.diagnostics.lines.joined().contains("https://"))
        XCTAssertFalse(String(reflecting: result).contains(secret))
        XCTAssertFalse((try XCTUnwrap(result) as NSError).localizedDescription.contains(secret))
    }
}
