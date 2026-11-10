import XCTest
@testable import WallpaperMachine

@MainActor
final class CreatorSettingsStoreTests: XCTestCase {
    private var root: URL!
    private var url: URL { root.appendingPathComponent("CreatorSettings.json") }
    private enum Probe: Error { case interrupted }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func profile(_ name: String = "Test", kind: ProviderProfile.ProtocolKind = .openaiCompatible) -> ProviderProfile {
        ProviderProfile(name: name, protocolKind: kind, baseURL: "https://api.example.test/v1", model: "test-model")
    }
    private func rejected<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("Accepted an invalid settings operation", file: file, line: line) } catch {}
    }

    func testProfilesAndSelectionPersistAcrossRestart() async throws {
        let store = CreatorSettingsStore(url: url)
        var saved = try await store.settings()
        XCTAssertTrue(saved.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for kind in ProviderProfile.ProtocolKind.allCases {
            saved = try await store.saveProfile(profile(kind.rawValue, kind: kind), expectedRevision: saved.revision)
        }
        let selected = saved.profiles[1].id
        saved = try await store.selectProfile(selected, expectedRevision: saved.revision)
        let reopened = try await CreatorSettingsStore(url: url).settings()
        XCTAssertEqual(reopened, saved)
        XCTAssertEqual(reopened.selectedProfileID, selected)
        XCTAssertEqual(reopened.profiles.map(\.protocolKind), ProviderProfile.ProtocolKind.allCases)
        XCTAssertEqual(Set(reopened.profiles.map(\.id)).count, 3)
    }

    func testSameHostProfilesAreIndependentAndChangedConfigurationFencesOldHandles() async throws {
        let store = CreatorSettingsStore(url: url)
        let first = try await store.saveProfile(profile("First"), expectedRevision: 0)
        var saved = try await store.saveProfile(profile("Second"), expectedRevision: first.revision)
        let original = saved.profiles[0], other = saved.profiles[1]
        var changed = original; changed.baseURL = "https://other.example.test/v1"
        saved = try await store.saveProfile(changed, expectedRevision: saved.revision)
        let updated = saved.profiles[0]
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.configurationRevision, original.configurationRevision + 1)
        XCTAssertNotEqual(updated.configurationID, original.configurationID)
        XCTAssertNotEqual(try updated.origin(), try original.origin())
        await rejected { try await store.profile(id: original.id, configurationID: original.configurationID) }
        let unchanged = try await store.profile(id: other.id, configurationID: other.configurationID)
        XCTAssertEqual(unchanged, other)
        let selected = try await store.selectProfile(updated.id, expectedRevision: saved.revision)
        XCTAssertEqual(selected.profiles, saved.profiles)
        let noChange = try await store.saveProfile(updated, expectedRevision: selected.revision)
        XCTAssertEqual(noChange, selected)
        var newModel = updated; newModel.model = "other-model"
        let next = try await store.saveProfile(newModel, expectedRevision: noChange.revision)
        XCTAssertNotEqual(next.profiles[0].configurationID, updated.configurationID)
        await rejected { try await store.saveProfile(updated, expectedRevision: next.revision) }
    }

    func testIndependentStoresRejectStaleEditsAndPreserveBothProfiles() async throws {
        let first = CreatorSettingsStore(url: url), second = CreatorSettingsStore(url: url)
        let initial = try await second.settings()
        let one = try await first.saveProfile(profile("One"), expectedRevision: initial.revision)
        do {
            _ = try await second.saveProfile(profile("Two"), expectedRevision: initial.revision)
            XCTFail("Overwrote a newer settings snapshot")
        } catch { XCTAssertEqual(error as? CreatorSettingsStore.Failure, .staleSettings) }
        let two = try await second.saveProfile(profile("Two"), expectedRevision: one.revision)
        let reloaded = try await first.settings()
        XCTAssertEqual(reloaded, two)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["One", "Two"])
    }

    func testConcurrentActorsHaveOneWinnerAndNeverLoseCommittedData() async throws {
        let target = url
        let profiles = (0..<12).map { profile("Profile \($0)") }
        let outcomes = await withTaskGroup(of: Result<CreatorSettings, Error>.self) { group in
            for profile in profiles {
                group.addTask {
                    do { return .success(try await CreatorSettingsStore(url: target).saveProfile(profile, expectedRevision: 0)) }
                    catch { return .failure(error) }
                }
            }
            var results: [Result<CreatorSettings, Error>] = []
            for await result in group { results.append(result) }
            return results
        }
        var successes = 0
        for result in outcomes {
            switch result {
            case .success: successes += 1
            case .failure(let error):
                if let value = error as? CreatorSettingsStore.Failure { XCTAssertEqual(value, .staleSettings) }
                else if case CreatorPersistence.Failure.busy = error {} else { XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(successes, 1)
        let store = CreatorSettingsStore(url: target)
        var saved = try await store.settings()
        for profile in profiles where !saved.profiles.contains(where: { $0.id == profile.id }) {
            saved = try await store.saveProfile(profile, expectedRevision: saved.revision)
        }
        XCTAssertEqual(Set(saved.profiles.map(\.id)), Set(profiles.map(\.id)))
        XCTAssertEqual(saved.revision, profiles.count)
    }

    func testFileLeaseRejectsAnotherWriterUntilReleased() async throws {
        let store = CreatorSettingsStore(url: url)
        var lease: CreatorPersistence.Lease? = try .init(url.appendingPathExtension("lock"))
        XCTAssertNotNil(lease)
        do { _ = try await store.saveProfile(profile(), expectedRevision: 0); XCTFail("Ignored the file lock") }
        catch { guard case CreatorPersistence.Failure.busy = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        lease = nil
        let saved = try await store.saveProfile(profile(), expectedRevision: 0)
        XCTAssertEqual(saved.profiles.count, 1)
    }

    func testRemovalClearsSelectionAndRecreationCannotReviveOldConfiguration() async throws {
        let store = CreatorSettingsStore(url: url)
        var saved = try await store.saveProfile(profile(), expectedRevision: 0)
        let old = saved.profiles[0]
        saved = try await store.selectProfile(old.id, expectedRevision: saved.revision)
        saved = try await store.removeProfile(old.id, expectedRevision: saved.revision)
        XCTAssertNil(saved.selectedProfileID)
        XCTAssertTrue(saved.profiles.isEmpty)
        await rejected { try await store.profile(id: old.id, configurationID: old.configurationID) }
        await rejected { try await store.selectProfile(old.id, expectedRevision: saved.revision) }
        var replacement = profile(); replacement.id = old.id
        saved = try await store.saveProfile(replacement, expectedRevision: saved.revision)
        XCTAssertNotEqual(saved.profiles[0].configurationID, old.configurationID)
        await rejected { try await store.profile(id: old.id, configurationID: old.configurationID) }
    }

    func testInterruptedAndCancelledAtomicWritesKeepLastSettings() async throws {
        let store = CreatorSettingsStore(url: url)
        let saved = try await store.saveProfile(profile(), expectedRevision: 0)
        let before = try Data(contentsOf: url)
        let interrupted = CreatorSettingsStore(url: url) { throw Probe.interrupted }
        await rejected { try await interrupted.selectProfile(saved.profiles[0].id, expectedRevision: saved.revision) }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let cancelled = CreatorSettingsStore(url: url) { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await cancelled.selectProfile(saved.profiles[0].id, expectedRevision: saved.revision) }
        do { _ = try await task.value; XCTFail("Committed after cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let reopened = try await CreatorSettingsStore(url: url).settings()
        XCTAssertEqual(reopened, saved)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".pending-") })
        let next = try await store.selectProfile(saved.profiles[0].id, expectedRevision: saved.revision)
        XCTAssertEqual(next.selectedProfileID, saved.profiles[0].id)
    }

    func testCorruptionUnknownVersionsAndSecretFieldsAreNotSilentlyReset() async throws {
        let store = CreatorSettingsStore(url: url)
        let saved = try await store.saveProfile(profile(), expectedRevision: 0)
        let before = try Data(contentsOf: url)
        var cases = [Data(before.dropLast()), before + Data([32])]
        var future = saved; future.schemaVersion = 2
        cases.append(try CreatorPersistence.record(future))
        future = saved; future.profiles[0].schemaVersion = 2
        cases.append(try CreatorPersistence.record(future))
        future = saved; future.profiles[0].limits.tokenBudget = 0
        cases.append(try CreatorPersistence.record(future))
        var object = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        var profiles = payload["profiles"] as! [[String: Any]]
        profiles[0]["apiKey"] = "test-only-secret"
        payload["profiles"] = profiles
        object["payload"] = payload
        object["digest"] = CreatorPersistence.hash(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
        cases.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        object = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        payload = object["payload"] as! [String: Any]; payload["revision"] = 99; object["payload"] = payload
        cases.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        for data in cases {
            try data.write(to: url)
            await rejected { try await CreatorSettingsStore(url: url).settings() }
            await rejected { try await store.saveProfile(profile("Replacement"), expectedRevision: saved.revision) }
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testProfileCountDuplicateIdentityAndSelectionBounds() async throws {
        let store = CreatorSettingsStore(url: url)
        var settings = CreatorSettings(revision: 32, profiles: (0..<32).map { index in
            var value = profile("Profile \(index)"); value.configurationRevision = 1; return value
        })
        try CreatorPersistence.write(settings, to: url)
        let full = try await store.settings()
        XCTAssertEqual(full.profiles.count, 32)
        let before = try Data(contentsOf: url)
        await rejected { try await store.saveProfile(profile("Overflow"), expectedRevision: full.revision) }
        XCTAssertEqual(try Data(contentsOf: url), before)
        settings.profiles[1].id = settings.profiles[0].id
        try CreatorPersistence.write(settings, to: url)
        await rejected { try await store.settings() }
        settings = full; settings.selectedProfileID = UUID()
        try CreatorPersistence.write(settings, to: url)
        await rejected { try await store.settings() }
        settings = full; settings.profiles[1].configurationID = settings.profiles[0].configurationID
        try CreatorPersistence.write(settings, to: url)
        await rejected { try await store.settings() }
    }

    func testLinkedOrOversizedSettingsAreRejectedWithoutTouchingTarget() async throws {
        let store = CreatorSettingsStore(url: url)
        _ = try await store.saveProfile(profile(), expectedRevision: 0)
        let original = try Data(contentsOf: url)
        let target = root.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        await rejected { try await store.settings() }
        await rejected { try await store.saveProfile(profile(), expectedRevision: 1) }
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.linkItem(at: target, to: url)
        await rejected { try await store.settings() }
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 32, count: 256 * 1024 + 1).write(to: url)
        await rejected { try await store.settings() }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
