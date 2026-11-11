import Foundation
import XCTest
@testable import WallpaperMachine

@MainActor
final class LLMTestContext {
    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        private var sleeps: [TimeInterval] = []
        var lines: [String] { lock.withLock { events } }
        var delays: [TimeInterval] { lock.withLock { sleeps } }
        func record(_ event: LLMLogEvent) { lock.withLock { events.append(event.description) } }
        func waited(_ seconds: TimeInterval) { lock.withLock { sleeps.append(seconds) } }
    }
    let root: URL
    let settings: CreatorSettingsStore
    let store: CreatorRevisionStore
    let memory: MemoryKeychain
    let credentials: ProviderCredentialStore
    let diagnostics: Diagnostics
    let profile: ProviderProfile
    let ticket: GenerationJob.Ticket
    let url: URL
    let route: LLMMockURLProtocol.Route
    let provider: LLMProvider

    init(kind: ProviderProfile.ProtocolKind = .openaiCompatible, requests: Int = 3, tokens: Int = 192,
         timeout: TimeInterval = 3, capabilities: ProviderProfile.Capabilities = .init(), bind: Bool = true) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-llm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = CreatorSettingsStore(url: root.appendingPathComponent("settings.json"))
        store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
        memory = MemoryKeychain(); credentials = ProviderCredentialStore(calls: memory)
        diagnostics = Diagnostics()
        var input = LLMTestFixtures.profile(kind)
        input.baseURL = "https://fixture-" + UUID().uuidString.lowercased() + ".invalid"
        input.capabilities = capabilities
        input.limits = .init(requestBudget: requests, tokenBudget: tokens)
        let document = try await settings.saveProfile(input, expectedRevision: 0)
        profile = try XCTUnwrap(document.profiles.first)
        if bind { try await credentials.bind(LLMTestFixtures.key, to: profile, settings: settings) }
        let project = try await store.createProject(title: "Network fixture")
        ticket = try await store.beginJob(projectID: project.id, requestBudget: requests, tokenBudget: tokens)
        url = try LLMRequestDescriptor.make(profile: profile, input: LLMTestFixtures.input, jsonMode: false).url
        route = LLMMockURLProtocol.Route([.init(chunks: [try LLMTestFixtures.body(for: kind)])])
        LLMMockURLProtocol.register(route, at: url)
        let diagnostics = diagnostics
        provider = LLMProvider(settings: settings, credentials: credentials,
            transport: .init(configuration: LLMMockURLProtocol.configuration(), limits: .init(timeout: timeout)),
            log: { diagnostics.record($0) }, wait: { seconds in try Task.checkCancellation(); diagnostics.waited(seconds) })
    }
    func run(profile: ProviderProfile? = nil, input: LLMRequest = LLMTestFixtures.input) async throws -> LLMProvider.Completion {
        let selected = profile ?? self.profile
        return try await provider.generate(input, profileID: selected.id, configurationID: selected.configurationID, ticket: ticket, store: store)
    }
    func cleanup() {
        LLMMockURLProtocol.remove(url)
        try? FileManager.default.removeItem(at: root)
    }
    func waitForRequest() async throws {
        let end = ContinuousClock.now + .seconds(2)
        while route.requests.isEmpty && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(route.requests.isEmpty)
    }
}
