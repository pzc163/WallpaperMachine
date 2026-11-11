import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorSoakTests: XCTestCase {
    func testLiveSoakAllowanceCoversDurationAndTeardown() {
        for (duration, expected) in [(1.0, 2400.0), (1800.0, 2400.0), (1800.5, 2400.5), (86_400.0, 87_000.0)] {
            XCTAssertEqual(CreatorSoakHarness.executionAllowance(duration: duration), expected)
            XCTAssertGreaterThanOrEqual(expected - duration, 600)
        }
    }
    func testShortSoakStartsSavedTemplatesOfflineAndSamplesPauseResizeMemoryAndStop() async throws {
        let report = await CreatorSoakHarness.run(duration: 0.8, interval: 0.05)
        try CreatorBenchmarkHarness.attach(report, name: "Creator soak short report", to: self)
        XCTAssertTrue(report.passed, report.failure ?? "")
        XCTAssertEqual(report.stoppedPages, 3)
        XCTAssertGreaterThanOrEqual(report.elapsedSeconds, 0.8)
        XCTAssertEqual(Set(report.samples.map(\.template)), ["gradient-v2", "stars-v2", "clock-v2"])
        XCTAssertEqual(Set(report.samples.map(\.paused)), [true, false])
        XCTAssertTrue(report.samples.allSatisfy { $0.responsive && $0.externalAttempts == 0 && $0.processTerminations == 0 && $0.paints > 0 })
        XCTAssertFalse(report.completedThirtyMinutes)
    }
    func testNetworkAttemptObserverHasPositiveControlWithoutExternalConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorRevisionStore(root: root)
        let revision = try await CreatorS14Fixtures.draft(store: store)
        let preview = try await CreatorPreview.make(projectID: revision.projectID, revisionID: revision.id, store: store)
        let surface = preview.surface; defer { surface.stop() }
        surface.page.addUserScript(WKUserScript(source: CreatorSoakHarness.observer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        try await surface.start()
        let end = ContinuousClock.now + .seconds(5)
        while !surface.page.isLoaded && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        let before = try await CreatorSoakHarness.evaluate(surface.page.webView, "__creatorSoak.external") as? Int
        XCTAssertEqual(before, 0)
        _ = try await CreatorSoakHarness.evaluate(surface.page.webView, "fetch('http://127.0.0.1:1/probe').catch(()=>{}); true")
        let after = try await CreatorSoakHarness.evaluate(surface.page.webView, "__creatorSoak.external") as? Int
        XCTAssertGreaterThan(try XCTUnwrap(after), 0)
    }
    func testCancelledSoakStopsEveryCreatedPageAndKeepsPartialEvidence() async throws {
        let task = Task { await CreatorSoakHarness.run(duration: 10, interval: 0.05) }
        try await Task.sleep(for: .milliseconds(500)); task.cancel()
        let report = await task.value
        XCTAssertFalse(report.passed); XCTAssertEqual(report.failure, "cancelled")
        XCTAssertLessThanOrEqual(report.stoppedPages, 3)
    }
    func testInvalidDurationCannotAllocatePagesAndNativeTimeoutDoesNotNeedPageHeartbeat() async throws {
        let report = await CreatorSoakHarness.run(duration: .infinity, interval: 10)
        XCTAssertEqual(report.failure, "invalidConfiguration"); XCTAssertEqual(report.stoppedPages, 0)
        do { _ = try await CreatorSoakHarness.bounded(timeout: .milliseconds(10), operation: { _ in }); XCTFail("Deadline did not fire") }
        catch CreatorRuntimeFailure.timeout {}
    }
}

@MainActor
final class CreatorSoakLiveTests: XCTestCase {
    func testThirtyMinuteSoak() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CREATOR_SOAK"] == "1" else { throw XCTSkip("Long WebKit soak requires explicit opt-in; routine gate runs the short pipeline.") }
        guard let duration = Double(env["CREATOR_SOAK_SECONDS"] ?? "1800"), (1...86_400).contains(duration),
              let interval = Double(env["CREATOR_SOAK_INTERVAL"] ?? "10"), interval >= 0.1 else { throw CreatorRuntimeFailure.invalidCapture }
        executionTimeAllowance = CreatorSoakHarness.executionAllowance(duration: duration)
        let report = await CreatorSoakHarness.run(duration: duration, interval: interval)
        try CreatorBenchmarkHarness.attach(report, name: "Creator soak long report", to: self)
        XCTAssertTrue(report.passed, report.failure ?? "")
        XCTAssertGreaterThanOrEqual(report.elapsedSeconds, duration)
        XCTAssertEqual(report.stoppedPages, 3)
    }
}
