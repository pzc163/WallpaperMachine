import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorRepairTests: XCTestCase {
    private actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }
    private func flow(_ c: LLMTestContext, capture: CreatorOrchestrator.Capture? = nil,
                      checkpoint: @escaping @Sendable (CreatorOrchestrator.Stage) async throws -> Void = { _ in }) -> CreatorOrchestrator {
        let publisher = CreatorPublisher(root: c.root.appendingPathComponent("publication"), library: c.root.appendingPathComponent("Library"),
            registry: CreatorRuntimeRegistry(url: c.root.appendingPathComponent("registry.json")))
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        let diagnostics = c.diagnostics
        let wait: @Sendable (TimeInterval) async throws -> Void = { seconds in try Task.checkCancellation(); diagnostics.waited(seconds) }
        if let capture { return CreatorOrchestrator(store: c.store, generator: generator, publisher: publisher, capture: capture, checkpoint: checkpoint, wait: wait) }
        return CreatorOrchestrator(store: c.store, generator: generator, publisher: publisher, checkpoint: checkpoint, wait: wait)
    }
    private func request(_ c: LLMTestContext, repairs: Int = 2, base: UUID? = nil, prompt: String = "深蓝星空，减少粒子，缓慢移动") -> CreatorOrchestrator.Request {
        .init(projectID: c.ticket.projectID, baseRevisionID: base, profileID: c.profile.id, configurationID: c.profile.configurationID,
              prompt: prompt, maxOutputTokens: 2048, maxRepairs: repairs)
    }
    private func reply(_ text: String) throws -> LLMMockURLProtocol.Reply { .init(chunks: [try LLMTestFixtures.openAI(text)]) }
    private func outOfRange() throws -> String {
        var object = try CreatorGenerationFixtures.object()
        var parameters = object["parameters"] as! [String: Any]; parameters["starDensity"] = 1000; object["parameters"] = parameters
        return try CreatorGenerationFixtures.text(object)
    }
    private func failed(_ operation: () async throws -> CreatorOrchestrator.Outcome) async -> CreatorOrchestrator.Failure? {
        do { _ = try await operation(); XCTFail("Unexpected success"); return nil }
        catch { return error as? CreatorOrchestrator.Failure }
    }

    func testRangeFailureRepairsWithNativeFieldDetailsAndFullRuntimeEvidence() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([try reply(outOfRange()), try reply(CreatorGenerationFixtures.output())])
        let result = try await flow(c).createAndSave(request(c))
        let document = try await c.store.conversation(projectID: result.projectID)
        let turn = try XCTUnwrap(document.turns.last)
        XCTAssertEqual(turn.requestCount, 2); XCTAssertEqual(turn.repairCount, 1)
        XCTAssertEqual(turn.state, .completed); XCTAssertNil(turn.failure)
        XCTAssertEqual(turn.reservedOutputTokens, 4096)
        XCTAssertNotNil(turn.attempts[0].usage)
        XCTAssertEqual(turn.attempts[0].issue?.fields, [.init(path: "parameters.starDensity", rule: .range)])
        XCTAssertEqual(result.sealed.generation?.iterationID, turn.id)
        XCTAssertEqual(result.sealed.generation?.repairIndex, 1)
        let report = try await c.store.report(projectID: result.projectID, revisionID: result.sealed.id)
        XCTAssertTrue(report.allowsPublication)
        let body = try XCTUnwrap(c.route.requests.last?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = json["messages"] as! [[String: Any]]
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((messages.last!["content"] as! String).utf8)) as? [String: Any])
        XCTAssertNotNil(context["repair"])
        let diagnostic = try JSONSerialization.data(withJSONObject: context["repair"]!)
        XCTAssertFalse(String(decoding: diagnostic, as: UTF8.self).contains("1000"))
        XCTAssertEqual(c.route.requests.count, 2)
    }

    func testMalformedThenMissingParameterRepairsTwiceWithoutCommittingInvalidDrafts() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        var object = try CreatorGenerationFixtures.object()
        var parameters = object["parameters"] as! [String: Any]; parameters.removeValue(forKey: "starDensity"); object["parameters"] = parameters
        c.route.replace([try reply("{\"schemaVersion\":"), try reply(CreatorGenerationFixtures.text(object)), try reply(CreatorGenerationFixtures.output("clock-v2"))])
        let result = try await flow(c).createAndSave(request(c))
        let document = try await c.store.conversation(projectID: result.projectID)
        let turn = try XCTUnwrap(document.turns.last)
        XCTAssertEqual(turn.requestCount, 3); XCTAssertEqual(turn.repairCount, 2)
        XCTAssertEqual(turn.attempts[1].issue?.fields, [.init(path: "parameters.starDensity", rule: .missing)])
        let project = try await c.store.project(result.projectID)
        XCTAssertEqual(project.revisionIDs, [result.draft.id, result.sealed.id])
        XCTAssertEqual(c.route.requests.count, 3)
    }

    func testThreeInvalidResponsesExhaustOneBudgetAndNeverSendFourthRequest() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([try reply(outOfRange()), try reply(outOfRange()), try reply(outOfRange()), try reply(CreatorGenerationFixtures.output())])
        let failure = await failed { try await flow(c).createAndSave(request(c)) }
        XCTAssertEqual(failure?.requestCount, 3); XCTAssertTrue(failure?.budgetExhausted == true)
        let document = try await c.store.conversation(projectID: c.ticket.projectID)
        let turn = try XCTUnwrap(document.turns.last)
        XCTAssertEqual(turn.state, .failed); XCTAssertEqual(turn.requestCount, 3)
        XCTAssertTrue(turn.budgetExhausted); XCTAssertEqual(turn.failure?.category, .malformedOutput)
        let project = try await c.store.project(c.ticket.projectID)
        XCTAssertTrue(project.revisionIDs.isEmpty); XCTAssertNil(project.activeJobID)
        for attempt in turn.attempts {
            let job = try await c.store.job(attempt.jobID)
            XCTAssertEqual(job.attemptCount, 1); XCTAssertTrue(job.isTerminal)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.jobURL(job.id).appendingPathComponent("candidate").path))
        }
        XCTAssertEqual(c.route.requests.count, 3)
    }

    func testProfileRequestAndTokenCapsAlsoBoundRepairAttempts() async throws {
        for (repairs, profileLimit, tokens, expected) in [(0, 3, 8192, 1), (1, 3, 8192, 2), (2, 2, 8192, 2), (2, 3, 4096, 2)] {
            let c = try await LLMTestContext(requests: profileLimit, tokens: tokens); defer { c.cleanup() }
            c.route.replace([try reply(outOfRange())])
            let failure = await failed { try await flow(c).createAndSave(request(c, repairs: repairs)) }
            XCTAssertEqual(failure?.requestCount, expected)
            XCTAssertEqual(c.route.requests.count, expected)
        }
    }

    func testRepairUsesTheSameOuterLedgerForAllThreeProtocols() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let c = try await LLMTestContext(kind: kind, tokens: 8192); defer { c.cleanup() }
            c.route.replace([.init(chunks: [try CreatorGenerationFixtures.response(outOfRange(), kind: kind)]),
                .init(chunks: [try CreatorGenerationFixtures.response(CreatorGenerationFixtures.output(), kind: kind)])])
            let result = try await flow(c).createAndSave(request(c))
            let conversation = try await c.store.conversation(projectID: result.projectID)
            XCTAssertEqual(conversation.turns.last?.requestCount, 2)
            XCTAssertEqual(c.route.requests.count, 2)
            XCTAssertEqual(result.sealed.generation?.protocolKind, kind)
        }
    }

    func testProviderRefusalStopsWithoutParameterRepair() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI("", reason: "content_filter")]), try reply(CreatorGenerationFixtures.output())])
        let failure = await failed { try await flow(c).createAndSave(request(c)) }
        XCTAssertEqual(failure?.issue?.category, .refused)
        XCTAssertEqual(c.route.requests.count, 1)
    }

    func testAutomaticJSONModeFallbackUsesOneOfTheSameThreeRequests() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(status: 400, chunks: [Data(#"{"error":{"param":"response_format","code":"unsupported_parameter"}}"#.utf8)]),
            try reply(outOfRange()), try reply(CreatorGenerationFixtures.output())])
        let result = try await flow(c).createAndSave(request(c))
        let conversation = try await c.store.conversation(projectID: result.projectID)
        XCTAssertEqual(conversation.turns.last?.requestCount, 3)
        XCTAssertEqual(conversation.turns.last?.attempts.first?.issue?.category, .jsonModeUnsupported)
        XCTAssertEqual(c.route.requests.count, 3)
        for (index, request) in c.route.requests.enumerated() {
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["response_format"] != nil, index == 0)
        }
    }

    func testUnauthorizedTerminatesWithoutRepairForEveryProtocol() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            let c = try await LLMTestContext(kind: kind, tokens: 8192); defer { c.cleanup() }
            c.route.replace([.init(status: 401), .init(chunks: [try CreatorGenerationFixtures.response(CreatorGenerationFixtures.output(), kind: kind)])])
            let failure = await failed { try await flow(c).createAndSave(request(c)) }
            XCTAssertEqual(failure?.issue?.category, .unauthorized)
            XCTAssertEqual(failure?.requestCount, 1); XCTAssertEqual(c.route.requests.count, 1)
            let document = try await c.store.conversation(projectID: c.ticket.projectID)
            XCTAssertEqual(document.turns.last?.state, .failed); XCTAssertEqual(document.turns.last?.repairCount, 0)
            XCTAssertTrue(c.diagnostics.delays.isEmpty)
        }
    }

    func testTimeoutNetworkAndTruncatedStreamsConsumeTheSameRepairBudget() async throws {
        let failures: [LLMMockURLProtocol.Reply] = [.init(failure: URLError(.timedOut)), .init(failure: URLError(.networkConnectionLost)),
            .init(chunks: [Data("data: {\"choices\":[".utf8)])]
        for response in failures {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            c.route.replace([response, try reply(CreatorGenerationFixtures.output())])
            let result = try await flow(c).createAndSave(request(c))
            let document = try await c.store.conversation(projectID: result.projectID)
            XCTAssertEqual(document.turns.last?.requestCount, 2)
            XCTAssertEqual(document.turns.last?.reservedOutputTokens, 4096)
            XCTAssertNotNil(document.turns.last?.attempts.first?.issue)
            XCTAssertEqual(c.route.requests.count, 2)
        }
    }

    func testRepeatedTimeoutsStopAtThreeAndExposeLastFailure() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(failure: URLError(.timedOut))])
        let failure = await failed { try await flow(c).createAndSave(request(c)) }
        XCTAssertEqual(failure?.issue?.category, .timeout); XCTAssertTrue(failure?.budgetExhausted == true)
        XCTAssertEqual(c.route.requests.count, 3)
        let document = try await c.store.conversation(projectID: c.ticket.projectID)
        XCTAssertEqual(document.turns.last?.attempts.map { $0.issue?.category }, [.timeout, .timeout, .timeout])
    }

    func testRateLimitWaitsAndServerRetryNeverCreateAnInnerBudget() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(status: 429, headers: ["Retry-After": "2"]), .init(status: 503), try reply(CreatorGenerationFixtures.output())])
        let result = try await flow(c).createAndSave(request(c))
        XCTAssertEqual(c.route.requests.count, 3)
        XCTAssertEqual(c.diagnostics.delays, [2, 0.5])
        let document = try await c.store.conversation(projectID: result.projectID)
        XCTAssertEqual(document.turns.last?.attempts.prefix(2).map { $0.issue?.category }, [.rateLimited, .server])
        XCTAssertFalse(c.diagnostics.lines.contains { $0.contains("retry") })
    }

    func testLongRetryAfterStopsWithoutShorteningProviderDelay() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(status: 429, headers: ["Retry-After": "120"]), try reply(CreatorGenerationFixtures.output())])
        let failure = await failed { try await flow(c).createAndSave(request(c)) }
        XCTAssertEqual(failure?.issue?.retryAfter, 120); XCTAssertEqual(c.route.requests.count, 1)
        XCTAssertTrue(c.diagnostics.delays.isEmpty)
    }

    func testProfileChangeWhileRepairPendingCannotSendOldCredentialsAgain() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([try reply(outOfRange()), try reply(CreatorGenerationFixtures.output())])
        let settings = c.settings, original = c.profile
        let owner = flow(c, checkpoint: { stage in
            if stage == .repairPending {
                var changed = original; changed.baseURL = "https://changed.invalid"
                let previous = try await settings.settings()
                _ = try await settings.saveProfile(changed, expectedRevision: previous.revision)
            }
        })
        let failure = await failed { try await owner.createAndSave(request(c)) }
        XCTAssertEqual(failure?.issue?.category, .staleInput); XCTAssertEqual(failure?.requestCount, 1)
        XCTAssertEqual(c.route.requests.count, 1)
        let history = try await c.store.conversation(projectID: c.ticket.projectID)
        XCTAssertEqual(history.turns.last?.state, .failed)
        XCTAssertEqual(history.turns.last?.requestCount, 1)
    }

    func testCancellationInStreamAndRepairPendingCannotSendAnotherRequest() async throws {
        for pending in [false, true] {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            if pending { c.route.replace([try reply(outOfRange()), try reply(CreatorGenerationFixtures.output())]) }
            else { c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())], hold: true)]) }
            let owner = flow(c, checkpoint: { if pending && $0 == .repairPending { throw CancellationError() } })
            let task = Task { try await owner.createAndSave(request(c)) }
            if !pending { try await c.waitForRequest(); task.cancel() }
            let failure = await failed { try await task.value }
            XCTAssertEqual(failure?.issue?.category, .cancelled); XCTAssertEqual(c.route.requests.count, 1)
            let document = try await c.store.conversation(projectID: c.ticket.projectID)
            XCTAssertEqual(document.turns.last?.state, .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("Library").path))
            if !pending { XCTAssertGreaterThan(c.route.stopCount, 0) }
        }
    }

    func testRuntimeFailureCreatesFreshRevisionAndRechecksRealWebKitAndPoster() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([try reply(CreatorGenerationFixtures.output()), try reply(CreatorGenerationFixtures.output("gradient-v2"))])
        let counter = Counter()
        let owner = flow(c, capture: { project, revision, store in
            if await counter.next() == 1 { throw CreatorRuntimeFailure.pageFailed }
            return try await CreatorPosterService().capture(projectID: project, revisionID: revision, store: store)
        })
        let result = try await owner.createAndSave(request(c))
        let document = try await c.store.conversation(projectID: result.projectID)
        let turn = try XCTUnwrap(document.turns.last)
        XCTAssertEqual(turn.requestCount, 2); XCTAssertEqual(turn.attempts.first?.issue?.category, .runtime)
        XCTAssertEqual(turn.attempts.first?.issue?.runtimeReason, .pageFailed)
        let project = try await c.store.project(result.projectID)
        XCTAssertEqual(project.revisionIDs.count, 3)
        let oldReport = try await c.store.report(projectID: project.id, revisionID: turn.attempts[0].draftRevisionID!)
        XCTAssertEqual(oldReport.results["runtime"], .notChecked)
        let final = try await c.store.report(projectID: project.id, revisionID: result.sealed.id)
        XCTAssertTrue(final.allowsPublication)
        XCTAssertEqual(project.selectedRevisionID, result.sealed.id)
    }

    func testRepairContextAndConversationNeverEchoCredentialsPathsOrUnknownFieldNames() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        var object = try CreatorGenerationFixtures.object()
        object["/Users/hidden/private-response"] = LLMTestFixtures.key
        c.route.replace([try reply(CreatorGenerationFixtures.text(object)), try reply(CreatorGenerationFixtures.output())])
        let result = try await flow(c).createAndSave(request(c, prompt: "紫色星空 /Users/me/.ssh/id_rsa token=private-token " + LLMTestFixtures.key))
        let document = try await c.store.conversation(projectID: result.projectID)
        XCTAssertEqual(document.turns.last?.attempts.first?.issue?.fields, [.init(path: "$", rule: .unexpected)])
        let persisted = try Data(contentsOf: c.store.conversationURL(result.projectID))
        for bytes in [persisted] + c.route.requests.compactMap(\.httpBody) {
            let text = String(decoding: bytes, as: UTF8.self)
            for secret in [LLMTestFixtures.key, "/Users", "id_rsa", "private-token", "private-response"] { XCTAssertFalse(text.contains(secret), secret) }
        }
        XCTAssertEqual(c.route.requests.count, 2)
    }
}
