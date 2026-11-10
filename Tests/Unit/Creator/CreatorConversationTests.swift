import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorConversationTests: XCTestCase {
    private enum SimulatedCrash: Error { case interrupted }
    private func begin(_ store: CreatorRevisionStore, _ c: LLMTestContext) async throws -> CreatorConversation.Ticket {
        try await store.beginIteration(projectID: c.ticket.projectID, base: nil, profile: c.profile, message: "紫色星空", maxRepairs: 2)
    }
    private func job(_ store: CreatorRevisionStore, _ c: LLMTestContext, _ turn: CreatorConversation.Ticket) async throws -> GenerationJob.Ticket {
        try await store.beginJob(projectID: c.ticket.projectID, requestBudget: 1, tokenBudget: 8192, iteration: turn)
    }
    private func rejected(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Invalid operation accepted", file: file, line: line) } catch {}
    }

    func testLegacyWorkspaceReadsEmptyConversationWithoutCreatingFile() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let original = try Data(contentsOf: c.store.projectURL(c.ticket.projectID).appendingPathComponent("project-meta.json"))
        let document = try await c.store.conversation(projectID: c.ticket.projectID)
        XCTAssertTrue(document.turns.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.conversationURL(c.ticket.projectID).path))
        XCTAssertEqual(try Data(contentsOf: c.store.projectURL(c.ticket.projectID).appendingPathComponent("project-meta.json")), original)
    }

    func testLiveIterationLeaseSurvivesGapBetweenModelAndRuntime() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        try await c.store.cancel(c.ticket)
        let ticket = try await begin(c.store, c)
        try await c.store.moveIteration(ticket, to: .runtime)
        let other = CreatorRevisionStore(root: c.store.root)
        let recovery = try await other.recover()
        XCTAssertEqual(recovery.liveIterations, [ticket.id]); XCTAssertTrue(recovery.interruptedIterations.isEmpty)
        let turn = try await c.store.iteration(ticket)
        XCTAssertEqual(turn.state, .runtime)
        try await c.store.closeIteration(ticket, state: .cancelled, issue: .init(category: .cancelled))
    }

    func testAbandonedRepairPendingRestartsAsInterruptedWithoutRefundOrRequest() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        try await c.store.cancel(c.ticket)
        var owner: CreatorRevisionStore? = CreatorRevisionStore(root: c.store.root)
        let ticket = try await begin(owner!, c)
        let attempt = try await job(owner!, c, ticket)
        _ = try await owner!.reserveLLMAttempt(attempt, profile: c.profile, outputTokens: 2048)
        try await owner!.savePartial(Data("partial".utf8), for: attempt)
        try await owner!.cancel(attempt)
        let allowed = try await owner!.pendingRepair(ticket, issue: .field("$", .syntax), outputTokens: 2048)
        XCTAssertTrue(allowed)
        owner = nil
        let recovered = CreatorRevisionStore(root: c.store.root)
        let recovery = try await recovered.recover()
        XCTAssertEqual(recovery.interruptedIterations, [ticket.id])
        let turn = try await recovered.iteration(ticket)
        XCTAssertEqual(turn.state, .interrupted); XCTAssertEqual(turn.requestCount, 1)
        XCTAssertEqual(turn.reservedOutputTokens, 2048); XCTAssertEqual(turn.failure?.category, .interrupted)
        XCTAssertTrue(c.route.requests.isEmpty)
        await rejected { try await recovered.resumeRepair(ticket) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovered.jobURL(attempt.id).appendingPathComponent("partial.bin").path))
        let secondRecovery = try await recovered.recover()
        XCTAssertTrue(secondRecovery.interruptedIterations.isEmpty)
    }

    func testCrashAfterWholeTurnReservationCannotRefundOrReuseBudget() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        try await c.store.cancel(c.ticket)
        var owner: CreatorRevisionStore? = CreatorRevisionStore(root: c.store.root, checkpoint: {
            if $0 == .afterIterationReservation { throw SimulatedCrash.interrupted }
        })
        let ticket = try await begin(owner!, c), attempt = try await job(owner!, c, ticket)
        await rejected { _ = try await owner!.reserveLLMAttempt(attempt, profile: c.profile, outputTokens: 2048) }
        let before = try await owner!.iteration(ticket), partialJob = try await owner!.job(attempt.id)
        XCTAssertEqual(before.requestCount, 1); XCTAssertEqual(partialJob.attemptCount, 0)
        await rejected { _ = try await owner!.reserveLLMAttempt(attempt, profile: c.profile, outputTokens: 2048) }
        let unchanged = try await owner!.iteration(ticket)
        XCTAssertEqual(unchanged.requestCount, 1)
        owner = nil
        let restarted = CreatorRevisionStore(root: c.store.root), recovery = try await restarted.recover()
        XCTAssertEqual(recovery.interruptedJobs, [attempt.id]); XCTAssertEqual(recovery.interruptedIterations, [ticket.id])
        let after = try await restarted.iteration(ticket)
        XCTAssertEqual(after.requestCount, 1); XCTAssertEqual(after.reservedOutputTokens, 2048)
        XCTAssertTrue(c.route.requests.isEmpty)
    }

    func testLegacyCounterAndFreshChildJobsCannotBypassWholeTurnLimit() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let ticket = try await begin(c.store, c)
        for index in 0..<3 {
            let attempt = try await job(c.store, c, ticket)
            await rejected { try await c.store.recordAttempt(attempt) }
            _ = try await c.store.reserveLLMAttempt(attempt, profile: c.profile, outputTokens: 2048)
            await rejected { _ = try await c.store.reserveLLMAttempt(attempt, profile: c.profile, outputTokens: 2048) }
            try await c.store.cancel(attempt)
            let allowed = try await c.store.pendingRepair(ticket, issue: .field("$", .syntax), outputTokens: 2048)
            XCTAssertEqual(allowed, index < 2)
            if allowed { try await c.store.resumeRepair(ticket) }
        }
        let extra = try await job(c.store, c, ticket)
        await rejected { _ = try await c.store.reserveLLMAttempt(extra, profile: c.profile, outputTokens: 2048) }
        let turn = try await c.store.iteration(ticket)
        XCTAssertEqual(turn.requestCount, 3); XCTAssertEqual(turn.reservedOutputTokens, 6144)
        try await c.store.closeIteration(ticket, state: .failed, issue: .field("$", .syntax), exhausted: true)
        XCTAssertTrue(c.route.requests.isEmpty)
    }

    func testSupersededTicketCannotChangeNewTurnOrWriteLateOutput() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let previous = try await begin(c.store, c), oldJob = try await job(c.store, c, previous)
        _ = try await c.store.reserveLLMAttempt(oldJob, profile: c.profile, outputTokens: 2048)
        let replacement = try await begin(c.store, c)
        await rejected { try await c.store.savePartial(Data("late".utf8), for: oldJob) }
        await rejected { try await c.store.resumeRepair(previous) }
        try await c.store.closeIteration(previous, state: .failed, issue: .field("$", .syntax))
        let old = try await c.store.iteration(previous), current = try await c.store.iteration(replacement)
        XCTAssertEqual(old.state, .cancelled); XCTAssertEqual(old.requestCount, 1)
        XCTAssertEqual(current.state, .generating); XCTAssertEqual(current.requestCount, 0)
        try await c.store.closeIteration(replacement, state: .cancelled, issue: .init(category: .cancelled))
    }

    func testInvalidLimitsAndUnknownConversationVersionFailClosed() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        for maxRepairs in [-1, 3] {
            await rejected { _ = try await c.store.beginIteration(projectID: c.ticket.projectID, base: nil, profile: c.profile, message: "星空", maxRepairs: maxRepairs) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.conversationURL(c.ticket.projectID).path))
        let ticket = try await begin(c.store, c)
        try await c.store.closeIteration(ticket, state: .cancelled, issue: .init(category: .cancelled))
        var document = try await c.store.conversation(projectID: c.ticket.projectID)
        document.schemaVersion = 2
        try CreatorPersistence.write(document, to: c.store.conversationURL(c.ticket.projectID))
        await rejected { _ = try await c.store.conversation(projectID: c.ticket.projectID) }
        let recovery = try await c.store.recover()
        XCTAssertEqual(recovery.invalidConversations, [c.ticket.projectID])
        XCTAssertTrue(c.route.requests.isEmpty)
    }

    func testConversationTamperingAndSymlinkCannotBeSilentlyReplaced() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let ticket = try await begin(c.store, c)
        try await c.store.closeIteration(ticket, state: .cancelled, issue: .init(category: .cancelled))
        let path = c.store.conversationURL(c.ticket.projectID), original = try Data(contentsOf: path)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        record["unknown"] = true
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: path)
        await rejected { _ = try await c.store.conversation(projectID: c.ticket.projectID) }
        try FileManager.default.removeItem(at: path)
        let outside = c.root.appendingPathComponent("unrelated.json")
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        await rejected { _ = try await begin(c.store, c) }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }
}
