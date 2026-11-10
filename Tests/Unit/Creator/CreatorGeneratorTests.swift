import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorGeneratorTests: XCTestCase {
    private enum Probe: Error { case interrupted }
    private func request(_ c: LLMTestContext, base: UUID? = nil, project: UUID? = nil) -> CreatorGenerator.Request {
        .init(projectID: project ?? c.ticket.projectID, baseRevisionID: base, profileID: c.profile.id,
              configurationID: c.profile.configurationID, prompt: "深蓝色夜空，缓慢移动", maxOutputTokens: 1024)
    }
    private func failure<T>(_ operation: () async throws -> T) async -> CreatorGenerationFailure? {
        do { _ = try await operation(); XCTFail("Unexpected generation success"); return nil }
        catch { return error as? CreatorGenerationFailure }
    }
    private func tree(_ directory: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
    func testEveryV2TemplateGeneratesThroughEveryCodecAndPersistsStaticEvidence() async throws {
        for kind in ProviderProfile.ProtocolKind.allCases {
            for definition in CreatorTemplateCatalog.all {
                let c = try await LLMTestContext(kind: kind, tokens: 8192); defer { c.cleanup() }
                let text = try CreatorGenerationFixtures.output(definition.id, parameters: definition.presets[1].parameters)
                let body = try CreatorGenerationFixtures.response(text, kind: kind)
                c.route.replace([.init(chunks: stride(from: 0, to: body.count, by: 7).map { body.subdata(in: $0..<min($0 + 7, body.count)) })])
                let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
                let revision = try await generator.generate(request(c))
                let metadata = try XCTUnwrap(revision.generation)
                XCTAssertEqual(revision.templateID, definition.id)
                XCTAssertEqual(revision.normalizedParameters, definition.presets[1].parameters)
                XCTAssertEqual(revision.providerID, c.profile.id.uuidString.lowercased())
                XCTAssertEqual(revision.modelID, c.profile.model); XCTAssertEqual(revision.outputSchemaVersion, 1)
                XCTAssertEqual(metadata.protocolKind, kind)
                XCTAssertEqual(metadata.configurationID, c.profile.configurationID)
                XCTAssertEqual(metadata.usage.inputTokens, 12); XCTAssertEqual(metadata.usage.outputTokens, 8)
                XCTAssertEqual(metadata.attemptCount, 1); XCTAssertEqual(metadata.reservedOutputTokens, 1024)
                let job = try await c.store.job(metadata.jobID)
                XCTAssertEqual(job.state, .completed); XCTAssertEqual(job.attemptCount, 1)
                let report = try await c.store.report(projectID: revision.projectID, revisionID: revision.id)
                XCTAssertTrue(report.allowsPreview)
                XCTAssertEqual(report.results["runtime"], .notChecked); XCTAssertEqual(report.results["posterCapture"], .notChecked)
                let snapshot = try await c.store.snapshot(projectID: revision.projectID, revisionID: revision.id)
                XCTAssertEqual(snapshot.bundleVersion, 2); XCTAssertEqual(snapshot.manifest?.packaging, .renderDraft)
                XCTAssertEqual(Set(snapshot.files.keys), ["creator.json", "project.json", "index.html"])
                XCTAssertEqual(snapshot.manifest?.presentation?.title, "夜色🌙")
                let reopened = CreatorRevisionStore(root: c.store.root)
                let restored = try await reopened.revision(projectID: revision.projectID, revisionID: revision.id)
                XCTAssertEqual(restored, revision)
                let files = try tree(c.store.root)
                XCTAssertFalse(files.values.contains { String(decoding: $0, as: UTF8.self).contains(LLMTestFixtures.key) })
                XCTAssertFalse(files.values.contains { String(decoding: $0, as: UTF8.self).contains("private thought") })
                XCTAssertFalse(c.diagnostics.lines.joined().contains("夜色"))
                XCTAssertEqual(c.route.requests.count, 1)
            }
        }
    }
    func testExplicitBaseRevisionCreatesNewHistoryAndKeepsPreviousBytesAndReports() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        let definition = try CreatorTemplateCatalog.definition("stars-v2")
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let first = try await generator.generate(request(c))
        let original = try tree(c.store.revisionURL(projectID: first.projectID, revisionID: first.id))
        var values = definition.defaults; values["primaryHue"] = .number(300)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output(parameters: values))])])
        let second = try await generator.generate(request(c, base: first.id))
        values = definition.defaults; values["starDensity"] = .number(0.2)
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output(parameters: values))])])
        let third = try await generator.generate(request(c, base: first.id))
        XCTAssertEqual(second.parentID, first.id); XCTAssertEqual(third.parentID, first.id)
        XCTAssertEqual(third.normalizedParameters["primaryHue"], .number(220))
        XCTAssertEqual(third.normalizedParameters["starDensity"], .number(0.2))
        XCTAssertEqual(try tree(c.store.revisionURL(projectID: first.projectID, revisionID: first.id)), original)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(c.route.requests.last?.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(sent["messages"] as? [[String: String]])
        let user = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(messages.last?["content"]).utf8)) as? [String: Any])
        XCTAssertEqual((user["base"] as? [String: Any])?["revisionID"] as? String, first.id.uuidString.lowercased())
        try await c.store.select(projectID: first.projectID, revisionID: first.id)
        let project = try await c.store.project(first.projectID)
        XCTAssertEqual(project.revisionIDs, [first.id, second.id, third.id]); XCTAssertEqual(project.selectedRevisionID, first.id)
    }
    func testWholeMarkdownFenceFlowsThroughTransportAndNativeCompiler() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.fenced(CreatorGenerationFixtures.output("clock-v2")))])])
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        let revision = try await generator.generate(request(c))
        XCTAssertEqual(revision.templateID, "clock-v2")
        XCTAssertEqual(c.route.requests.count, 1)
    }
    func testMalformedPolicyAndTruncatedResponsesLeaveNoCandidateOrRevision() async throws {
        var unknown = try CreatorGenerationFixtures.object(); unknown["templateID"] = "../outside"
        var extra = try CreatorGenerationFixtures.object(); extra["files"] = [["path": "../escaped.js", "content": "x"]]
        var range = try CreatorGenerationFixtures.object()
        var values = try XCTUnwrap(range["parameters"] as? [String: Any]); values["starDensity"] = 100; range["parameters"] = values
        let cases: [(Data, CreatorGenerationFailure)] = [
            (try LLMTestFixtures.openAI(CreatorGenerationFixtures.text(unknown)), .policyViolation),
            (try LLMTestFixtures.openAI(CreatorGenerationFixtures.text(extra)), .policyViolation),
            (try LLMTestFixtures.openAI(CreatorGenerationFixtures.text(range)), .malformedOutput),
            (try LLMTestFixtures.openAI("{\"truncated\":"), .malformedOutput),
            (try LLMTestFixtures.openAI("{\"large\":\"" + String(repeating: "a", count: 16 * 1024) + "\"}"), .malformedOutput),
            (try LLMTestFixtures.openAI(CreatorGenerationFixtures.output(), done: false), .malformedOutput),
        ]
        for (body, expected) in cases {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            c.route.replace([.init(chunks: [body])])
            let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
            let result = await failure { try await generator.generate(request(c)) }
            XCTAssertEqual(result, expected)
            let project = try await c.store.project(c.ticket.projectID)
            XCTAssertTrue(project.revisionIDs.isEmpty); XCTAssertNil(project.activeJobID)
            let files = try tree(c.root)
            XCTAssertFalse(files.keys.contains { $0.contains("candidate/") || $0.contains("partial.bin") || $0.contains("escaped.js") })
            XCTAssertEqual(c.route.requests.count, 1)
        }
    }
    func testCancellationDuringStreamingStopsRequestAndLeavesNoRevision() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        let partial = try LLMTestFixtures.frame(["choices": [["index": 0, "delta": ["content": "{\"schemaVersion\":"], "finish_reason": NSNull()]]])
        c.route.replace([.init(chunks: [partial], hold: true)])
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        let task = Task { try await generator.generate(request(c)) }
        try await c.waitForRequest()
        let running = try await c.store.project(c.ticket.projectID)
        let jobID = try XCTUnwrap(running.activeJobID)
        task.cancel()
        let result = await failure { try await task.value }
        XCTAssertEqual(result, .cancelled)
        let job = try await c.store.job(jobID)
        XCTAssertEqual(job.state, .cancelled); XCTAssertEqual(job.attemptCount, 1)
        let project = try await c.store.project(c.ticket.projectID)
        XCTAssertTrue(project.revisionIDs.isEmpty)
        XCTAssertFalse(try tree(c.root).keys.contains { $0.contains("candidate/") || $0.contains("partial.bin") })
    }
    func testCancellationAtEveryLocalStageDiscardsStagedPackage() async throws {
        for target in [CreatorGenerator.Checkpoint.beforeRequest, .afterResponse, .afterValidation, .beforeCommit] {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
            let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider) { point in
                if point == target { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let result = await failure { try await generator.generate(request(c)) }
            XCTAssertEqual(result, .cancelled)
            let project = try await c.store.project(c.ticket.projectID)
            XCTAssertTrue(project.revisionIDs.isEmpty); XCTAssertNil(project.activeJobID)
            XCTAssertFalse(try tree(c.root).keys.contains { $0.contains("candidate/") })
            XCTAssertEqual(c.route.requests.count, target == .beforeRequest ? 0 : 1)
        }
    }
    func testRetryBudgetIsReservedOncePerRequestAndUsageRemainsRequestScoped() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(status: 429, headers: ["Retry-After": "0"]), .init(status: 503),
                         .init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        let revision = try await generator.generate(request(c))
        let metadata = try XCTUnwrap(revision.generation)
        let job = try await c.store.job(metadata.jobID)
        XCTAssertEqual(job.attemptCount, 3); XCTAssertEqual(metadata.attemptCount, 3)
        XCTAssertEqual(job.reservedOutputTokens, 3072); XCTAssertEqual(metadata.reservedOutputTokens, 3072)
        XCTAssertEqual(metadata.usage.totalTokens, 20)
        XCTAssertEqual(c.route.requests.count, 3)
    }
    func testExhaustedBudgetAndUnknownUsageNeverInventSuccessOrTokenCounts() async throws {
        for unknown in [false, true] {
            let c = try await LLMTestContext(requests: 1, tokens: 1024); defer { c.cleanup() }
            c.route.replace(unknown ? [.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output(), usage: nil)])] : [.init(status: 503)])
            let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
            if unknown {
                let revision = try await generator.generate(request(c))
                XCTAssertTrue(try XCTUnwrap(revision.generation).usage.isUnknown)
                let restored = try await c.store.revision(projectID: revision.projectID, revisionID: revision.id)
                XCTAssertNil(restored.generation?.usage.totalTokens)
            } else {
                let result = await failure { try await generator.generate(request(c)) }
                XCTAssertEqual(result, .transport(.server(503)))
                let project = try await c.store.project(c.ticket.projectID)
                XCTAssertTrue(project.revisionIDs.isEmpty)
            }
            XCTAssertEqual(c.route.requests.count, 1)
        }
    }
    func testAChangedBaseAfterResponseCannotBecomeANewRevision() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let first = try await CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider).generate(request(c))
        let metadataURL = c.store.revisionURL(projectID: first.projectID, revisionID: first.id).appendingPathComponent("revision.json")
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider) { point in
            if point == .afterResponse {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CreatorPersistence.encode(first)) as? [String: Any])
                object["promptSummary"] = "Modified after request"
                let changed = try JSONDecoder().decode(CreatorRevision.self, from: JSONSerialization.data(withJSONObject: object))
                try CreatorPersistence.write(changed, to: metadataURL)
            }
        }
        let result = await failure { try await generator.generate(request(c, base: first.id)) }
        XCTAssertEqual(result, .staleInput)
        let project = try await c.store.project(first.projectID)
        XCTAssertEqual(project.revisionIDs, [first.id])
        XCTAssertFalse(try tree(c.root).keys.contains { $0.contains("candidate/") })
    }
    func testNewGenerationSupersedesHeldStreamWithoutLettingOldCallbacksCommit() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(hold: true), .init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output("gradient-v2"))])])
        let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
        let old = Task { try await generator.generate(request(c)) }
        try await c.waitForRequest()
        let revision = try await generator.generate(request(c))
        let result = await failure { try await old.value }
        XCTAssertEqual(result, .cancelled)
        let project = try await c.store.project(c.ticket.projectID)
        XCTAssertEqual(project.revisionIDs, [revision.id]); XCTAssertEqual(project.selectedRevisionID, revision.id)
        XCTAssertEqual(c.route.requests.count, 2)
    }
    func testGeneratedProvenanceTamperingInvalidatesExistingReport() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let revision = try await CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider).generate(request(c))
        let path = c.store.revisionURL(projectID: revision.projectID, revisionID: revision.id).appendingPathComponent("revision.json")
        let original = try Data(contentsOf: path)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CreatorPersistence.encode(revision)) as? [String: Any])
        var metadata = try XCTUnwrap(object["generation"] as? [String: Any])
        var usage = try XCTUnwrap(metadata["usage"] as? [String: Any])
        usage["outputTokens"] = 99; metadata["usage"] = usage; object["generation"] = metadata
        let changed = try JSONDecoder().decode(CreatorRevision.self, from: JSONSerialization.data(withJSONObject: object))
        try CreatorPersistence.write(changed, to: path)
        let readable = try await c.store.revision(projectID: revision.projectID, revisionID: revision.id)
        XCTAssertEqual(readable.bundleDigest, revision.bundleDigest)
        do { _ = try await c.store.snapshot(projectID: revision.projectID, revisionID: revision.id); XCTFail("Reused stale provenance evidence") }
        catch { XCTAssertEqual(error as? CreatorPersistence.Failure, .staleValidation) }
        try original.write(to: path)
        let restored = try await c.store.snapshot(projectID: revision.projectID, revisionID: revision.id)
        XCTAssertEqual(restored.digest, revision.bundleDigest)
    }
    func testProfileChangeAfterResponseCancelsPackagingWithoutAnotherRequest() async throws {
        let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
        c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
        let settings = c.settings, profile = c.profile
        let generator = CreatorGenerator(store: c.store, settings: settings, provider: c.provider) { point in
            if point == .beforeCommit {
                let current = try await settings.settings()
                var changed = profile; changed.baseURL = "https://new.invalid"
                _ = try await settings.saveProfile(changed, expectedRevision: current.revision)
            }
        }
        let result = await failure { try await generator.generate(request(c)) }
        XCTAssertEqual(result, .transport(.staleProfile))
        let project = try await c.store.project(c.ticket.projectID)
        XCTAssertTrue(project.revisionIDs.isEmpty)
        XCTAssertEqual(c.route.requests.count, 1)
        XCTAssertFalse(try tree(c.root).keys.contains { $0.contains("candidate/") })
    }
    func testLegacyCatalogRevisionCanBeABaseWhileS0RequiresAnExplicitUpgrade() async throws {
        for enhanced in [false, true] {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            let specification = try enhanced
                ? CreatorTemplateCatalog.definition("stars-v2").specification(projectID: c.ticket.projectID)
                : CreatorTemplate.Specification(projectID: c.ticket.projectID, kind: .stars)
            let parent = try await c.store.stage(specification, for: c.ticket, legacy: true)
            _ = try await c.store.commit(c.ticket)
            let bytes = try tree(c.store.revisionURL(projectID: parent.projectID, revisionID: parent.id))
            c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
            let generator = CreatorGenerator(store: c.store, settings: c.settings, provider: c.provider)
            if enhanced {
                let child = try await generator.generate(request(c, base: parent.id))
                XCTAssertEqual(child.parentID, parent.id)
                XCTAssertEqual(parent.bundleVersion, 1); XCTAssertEqual(child.bundleVersion, 2)
            } else {
                let result = await failure { try await generator.generate(request(c, base: parent.id)) }
                XCTAssertEqual(result, .policyViolation); XCTAssertTrue(c.route.requests.isEmpty)
            }
            XCTAssertEqual(try tree(c.store.revisionURL(projectID: parent.projectID, revisionID: parent.id)), bytes)
        }
    }
    func testInterruptionAroundAtomicCommitLeavesEitherNothingOrAValidatedWholeRevision() async throws {
        for boundary in [CreatorRevisionStore.Checkpoint.afterRevisionMove, .afterProjectCommit] {
            let c = try await LLMTestContext(tokens: 8192); defer { c.cleanup() }
            let owner = CreatorRevisionStore(root: c.root.appendingPathComponent("interrupted"), checkpoint: { point in
                if point == boundary { throw Probe.interrupted }
            })
            let project = try await owner.createProject(title: "Atomic generation")
            c.route.replace([.init(chunks: [try LLMTestFixtures.openAI(CreatorGenerationFixtures.output())])])
            let generator = CreatorGenerator(store: owner, settings: c.settings, provider: c.provider)
            let result = await failure { try await generator.generate(request(c, project: project.id)) }
            XCTAssertEqual(result, .storage)
            let reopened = CreatorRevisionStore(root: owner.root)
            _ = try await reopened.recover()
            let state = try await reopened.project(project.id)
            XCTAssertEqual(state.revisionIDs.count, boundary == .afterProjectCommit ? 1 : 0)
            if let id = state.revisionIDs.first {
                let report = try await reopened.report(projectID: project.id, revisionID: id)
                XCTAssertTrue(report.allowsPreview); XCTAssertEqual(report.results["runtime"], .notChecked)
                XCTAssertEqual(state.selectedRevisionID, id)
            }
        }
    }
}
