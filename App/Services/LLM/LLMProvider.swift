import Foundation

/// Runs bounded native jobs; complete answers remain in memory for S1.3's independent validation.
actor LLMProvider {
    struct Completion: Sendable {
        let response: LLMResponse
        let profile: ProviderProfile
        let ticket: GenerationJob.Ticket
        let attempts: Int
        let reservedOutputTokens: Int
        let elapsed: TimeInterval
    }
    private let settings: CreatorSettingsStore
    private let credentials: ProviderCredentialStore
    private let transport: LLMStreamTransport
    private let log: @Sendable (LLMLogEvent) -> Void
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private var active: [UUID: (ticket: GenerationJob.Ticket, cancellation: LLMCancellation)] = [:]

    init(settings: CreatorSettingsStore, credentials: ProviderCredentialStore, transport: LLMStreamTransport = .init(),
         log: @escaping @Sendable (LLMLogEvent) -> Void = { AppLog.info($0.description) },
         wait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.settings = settings; self.credentials = credentials; self.transport = transport; self.log = log; self.wait = wait
    }
    func generate(_ input: LLMRequest, profileID: UUID, configurationID: UUID,
                  ticket: GenerationJob.Ticket, store: CreatorRevisionStore) async throws -> Completion {
        guard active[ticket.id] == nil, active.count < 4 else { throw LLMFailure.busy }
        let cancellation = LLMCancellation()
        active[ticket.id] = (ticket, cancellation)
        defer { active[ticket.id] = nil; cancellation.clear() }
        let settings = settings, credentials = credentials, transport = transport, log = log, wait = wait
        let operation = Task {
            try await Self.run(input, profileID: profileID, configurationID: configurationID, ticket: ticket, store: store,
                settings: settings, credentials: credentials, transport: transport, cancellation: cancellation, log: log, wait: wait)
        }
        cancellation.install { operation.cancel() }
        do {
            return try await withTaskCancellationHandler { try await operation.value } onCancel: { cancellation.cancel() }
        } catch {
            let failure = cancellation.failure ?? LLMFailure.sanitized(error)
            log(.failed(failure))
            // A competing provider or file-lock owner must not have its job cancelled by us.
            if failure != .busy {
                do { try await store.cancel(ticket) } catch { log(.failed(.invalidJob)) }
            }
            throw failure
        }
    }
    func cancel(_ ticket: GenerationJob.Ticket) {
        if active[ticket.id]?.ticket == ticket { active[ticket.id]?.cancellation.cancel() }
    }

    private static func run(_ input: LLMRequest, profileID: UUID, configurationID: UUID, ticket: GenerationJob.Ticket,
                            store: CreatorRevisionStore, settings: CreatorSettingsStore, credentials: ProviderCredentialStore,
                            transport: LLMStreamTransport, cancellation: LLMCancellation,
                            log: @Sendable (LLMLogEvent) -> Void,
                            wait: @Sendable (TimeInterval) async throws -> Void) async throws -> Completion {
        try input.validate(); try cancellation.check()
        let profile: ProviderProfile
        do { profile = try await settings.profile(id: profileID, configurationID: configurationID) }
        catch { throw LLMFailure.staleProfile }
        do { _ = try await store.generatingJob(ticket) } catch { throw LLMFailure.invalidJob }
        let registration = try await settings.withCurrentProfile(profile) { _ in
            try cancellation.check()
            return try LLMRequestCoordinator.shared.register(settingsURL: settings.url, profile: profile,
                jobURL: store.jobURL(ticket.id), ticket: ticket, cancel: { cancellation.cancel($0) })
        }
        defer { LLMRequestCoordinator.shared.remove(registration) }
        // Store writes in this process cancel synchronously; active-only monitoring covers another
        // process or external file replacement without an idle filesystem watcher.
        let monitor = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                do { try await settings.withCurrentProfile(profile) { _ in } }
                catch LLMFailure.busy { continue }
                catch { cancellation.cancel(.staleProfile); return }
                do { _ = try await store.generatingJob(ticket) }
                catch CreatorPersistence.Failure.busy { continue }
                catch { cancellation.cancel(.invalidJob); return }
            }
        }
        defer { monitor.cancel() }
        let started = ContinuousClock.now
        var jsonMode = profile.capabilities.jsonMode != .disabled
        while true {
            try cancellation.check()
            let grant = try await credentials.resolve(for: profile, settings: settings)
            let descriptor = try LLMRequestDescriptor.make(profile: profile, input: input, jsonMode: jsonMode)
            let request = try grant.request(descriptor)
            let job: GenerationJob
            do { job = try await store.reserveLLMAttempt(ticket, profile: profile, outputTokens: input.maxOutputTokens) }
            catch let failure as LLMFailure { throw failure }
            catch { throw LLMFailure.invalidJob }
            log(.started(attempt: job.attemptCount))
            do {
                let response = try await transport.perform(request, decoder: LLMRequestDescriptor.decoder(for: profile)) { task in
                    try cancellation.check()
                    do { _ = try await store.generatingJob(ticket) } catch { throw LLMFailure.invalidJob }
                    try await settings.withCurrentProfile(profile) { _ in
                        try cancellation.check()
                        task.resume()
                    }
                }
                try cancellation.check()
                try await settings.withCurrentProfile(profile) { _ in }
                do { _ = try await store.generatingJob(ticket) } catch { throw LLMFailure.invalidJob }
                log(.completed(attempts: job.attemptCount))
                let elapsed = started.duration(to: .now).components
                return Completion(response: response, profile: profile, ticket: ticket, attempts: job.attemptCount,
                    reservedOutputTokens: job.reservedOutputTokens ?? 0, elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            } catch {
                try cancellation.check()
                let failure = LLMFailure.sanitized(error)
                log(.failed(failure))
                let delay: TimeInterval
                switch failure {
                case .jsonModeUnsupported where profile.protocolKind == .openaiCompatible && jsonMode && (profile.capabilities.jsonMode ?? .automatic) == .automatic:
                    jsonMode = false; delay = 0
                case .rateLimited(let retryAfter):
                    delay = retryAfter ?? 1
                    guard delay <= 30 else { throw failure }
                case .server: delay = min(2, 0.5 * pow(2, Double(job.attemptCount - 1)))
                default: throw failure
                }
                guard job.attemptCount < min(job.requestBudget, profile.limits.requestBudget),
                      input.maxOutputTokens <= min(job.tokenBudget, profile.limits.tokenBudget) - (job.reservedOutputTokens ?? 0)
                else { throw failure }
                log(.retry(attempt: job.attemptCount + 1))
                try await wait(delay)
            }
        }
    }
}
