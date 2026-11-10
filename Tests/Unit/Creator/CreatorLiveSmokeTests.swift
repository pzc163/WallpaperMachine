import Foundation
import XCTest
@testable import WallpaperMachine

/// Explicitly opted-in only. The regular gate returns before creating any network client.
@MainActor
final class CreatorLiveSmokeTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { if values.count < 64 { values.append(value) } } }
        var snapshot: [String] { lock.withLock { values } }
    }

    func testSingleLiveCreationAndSave() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CREATOR_LIVE_LLM"] == "1" else {
            throw XCTSkip("Live creator smoke is opt-in; routine tests use mock model streams.")
        }
        guard let kind = env["CREATOR_LIVE_PROTOCOL"].flatMap(ProviderProfile.ProtocolKind.init(rawValue:)),
              let endpoint = env["CREATOR_LIVE_ENDPOINT"], let model = env["CREATOR_LIVE_MODEL"]
        else { throw CreatorGenerationFailure.invalidRequest }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = Events()
        var evidence: [String: Any] = ["protocol": kind.rawValue, "status": "failed", "requestBudget": 1]
        do {
            var input = ProviderProfile(name: "Temporary live smoke", protocolKind: kind, baseURL: endpoint, model: model)
            input.localMode = env["CREATOR_LIVE_LOCAL_MODE"] == "1"
            input.limits = .init(requestBudget: 1, tokenBudget: 2048)
            if kind == .openaiCompatible {
                input.capabilities.jsonMode = env["CREATOR_LIVE_JSON_MODE"] == "disabled" ? .disabled : .required
            }
            try input.validate()
            let settings = CreatorSettingsStore(url: root.appendingPathComponent("settings.json"))
            let document = try await settings.saveProfile(input, expectedRevision: 0)
            let profile = try XCTUnwrap(document.profiles.first)
            let memory = MemoryKeychain()
            let credentials = ProviderCredentialStore(calls: memory)
            // The Python runner strips the API key before launching Xcode, whose test
            // configuration may be persisted. Only this one-shot loopback reply carries it.
            let key = try await Self.temporaryKey(env)
            if key.isEmpty {
                guard profile.allowsEmptyKey else { throw CreatorGenerationFailure.invalidRequest }
            } else { try await credentials.bind(key, to: profile, settings: settings) }
            let store = CreatorRevisionStore(root: root.appendingPathComponent("Creator"))
            let registry = CreatorRuntimeRegistry(url: root.appendingPathComponent("registry.json"))
            let provider = LLMProvider(settings: settings, credentials: credentials, log: { events.add($0.description) })
            let generator = CreatorGenerator(store: store, settings: settings, provider: provider)
            let publisher = CreatorPublisher(root: root.appendingPathComponent("publication"), library: root.appendingPathComponent("Library"), registry: registry)
            let flow = CreatorOrchestrator(store: store, generator: generator, publisher: publisher,
                checkpoint: { events.add("stage:" + $0.rawValue) })
            let result = try await flow.createAndSave(.init(title: "Live smoke", profileID: profile.id,
                configurationID: profile.configurationID, prompt: env["CREATOR_LIVE_PROMPT"] ?? "创建深蓝紫色星空，缓慢移动，右下角显示时钟。", maxOutputTokens: 2048))
            let publication = try await store.publication(projectID: result.projectID, revisionID: result.sealed.id)
            let installed = try CreatorRuntimeRegistry.readForPlayback(result.installedDirectory, registryURL: registry.url)
            XCTAssertEqual(installed.digest, result.sealed.bundleDigest)
            XCTAssertEqual(result.sealed.generation?.attemptCount, 1)
            evidence["status"] = "passed"
            evidence["validatedOutput"] = ["schemaVersion": 1, "templateID": result.sealed.templateID,
                "parameters": result.sealed.normalizedParameters.mapValues(\.json),
                "title": installed.manifest?.presentation?.title ?? "", "summary": installed.manifest?.presentation?.summary ?? ""]
            evidence["generation"] = try JSONSerialization.jsonObject(with: CreatorPersistence.encode(result.sealed.generation))
            evidence["validation"] = try JSONSerialization.jsonObject(with: CreatorPersistence.encode(publication.binding.report))
            events.add("stage:completed")
            attach(evidence, events: events)
            let poster = XCTAttachment(data: installed.files["preview.jpg"]!, uniformTypeIdentifier: "public.jpeg")
            poster.name = "Creator live native preview"; poster.lifetime = .keepAlways; add(poster)
        } catch {
            if let flow = error as? CreatorOrchestrator.Failure { evidence["failure"] = flow.description }
            else { evidence["failure"] = CreatorGenerationFailure.sanitized(error).description }
            attach(evidence, events: events)
            throw CreatorGenerationFailure.invalidRequest // No raw transport, configuration, URL or key in XCTest errors.
        }
    }

    private func attach(_ input: [String: Any], events: Events) {
        var evidence = input; evidence["events"] = events.snapshot
        if let bytes = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
            attachment.name = "Creator live sanitized outcome"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private static func temporaryKey(_ env: [String: String]) async throws -> String {
        guard env["CREATOR_LIVE_API_KEY"] == nil, env["TEST_RUNNER_CREATOR_LIVE_API_KEY"] == nil,
              let port = env["CREATOR_LIVE_BROKER_PORT"].flatMap(Int.init), (1...65535).contains(port),
              let token = env["CREATOR_LIVE_BROKER_TOKEN"], (32...128).contains(token.utf8.count)
        else { throw CreatorGenerationFailure.invalidRequest }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/credential")!)
        request.httpMethod = "POST"; request.timeoutInterval = 3
        request.setValue(token, forHTTPHeaderField: "X-Creator-Smoke-Token")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096,
              let key = String(data: data, encoding: .utf8) else { throw CreatorGenerationFailure.invalidRequest }
        return key
    }
}
