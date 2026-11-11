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
        let effectiveJSONMode: ProviderProfile.Capabilities.JSONMode
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
                  ticket: GenerationJob.Ticket, store: CreatorRevisionStore, retrying: Bool = true,
                  outputMode: ProviderProfile.Capabilities.JSONMode? = nil,
                  streaming: Bool = true,
                  progress: @escaping @Sendable (LLMStreamProgress) -> Void = { _ in },
                  validate: @escaping @Sendable (String) throws -> Void = { _ in },
                  received: @escaping @Sendable (LLMResponse) async throws -> Void = { _ in }) async throws -> Completion {
        guard active[ticket.id] == nil, active.count < 4 else { throw LLMFailure.busy }
        let cancellation = LLMCancellation()
        active[ticket.id] = (ticket, cancellation)
        defer { active[ticket.id] = nil; cancellation.clear() }
        let settings = settings, credentials = credentials, transport = transport, log = log, wait = wait
        let operation = Task {
            try await Self.run(input, profileID: profileID, configurationID: configurationID, ticket: ticket, store: store,
                settings: settings, credentials: credentials, transport: transport, cancellation: cancellation, log: log, wait: wait,
                retrying: retrying, outputMode: outputMode, streaming: streaming, progress: progress, validate: validate, received: received)
        }
        cancellation.install { operation.cancel() }
        do {
            return try await withTaskCancellationHandler { try await operation.value } onCancel: { cancellation.cancel() }
        } catch {
            let failure = cancellation.failure ?? Self.diagnostic(error)
            log(.failed(failure))
            // A competing provider or file-lock owner must not have its job cancelled by us.
            if failure != .busy {
                do { try await store.cancel(ticket) } catch { log(.failed(.invalidJob)) }
            }
            if cancellation.failure == nil, let issue = error as? CreatorRepairIssue { throw issue }
            throw failure
        }
    }
    func cancel(_ ticket: GenerationJob.Ticket) {
        if active[ticket.id]?.ticket == ticket { active[ticket.id]?.cancellation.cancel() }
    }

    func sanitizedContext(_ texts: [String], profile: ProviderProfile) async throws -> [String] {
        guard texts.count <= 3, texts.allSatisfy({ $0.utf8.count <= 2048 }) else { throw LLMFailure.invalidInput }
        let grant = try await credentials.resolve(for: profile, settings: settings)
        return texts.map { CreatorConversationText.sanitize(grant.redacting($0)) }
    }

    func checkSourceContainsNoCredential(_ text: String, profile: ProviderProfile) async throws {
        guard text.utf8.count <= 40 * 1024 else { throw LLMFailure.outputLimit }
        let grant = try await credentials.resolve(for: profile, settings: settings)
        guard grant.redacting(text) == text else { throw CreatorRepairIssue.field("$", .text, policy: true) }
    }

    private static func diagnostic(_ error: Error) -> LLMFailure {
        if let issue = error as? CreatorRepairIssue {
            return issue.category == .jsonModeUnsupported ? .jsonModeUnsupported : .protocolViolation
        }
        return LLMFailure.sanitized(error)
    }

    private static func run(_ input: LLMRequest, profileID: UUID, configurationID: UUID, ticket: GenerationJob.Ticket,
                            store: CreatorRevisionStore, settings: CreatorSettingsStore, credentials: ProviderCredentialStore,
                            transport: LLMStreamTransport, cancellation: LLMCancellation,
                            log: @Sendable (LLMLogEvent) -> Void,
                            wait: @Sendable (TimeInterval) async throws -> Void, retrying: Bool,
                            outputMode: ProviderProfile.Capabilities.JSONMode?, streaming: Bool,
                            progress: @escaping @Sendable (LLMStreamProgress) -> Void,
                            validate: @Sendable (String) throws -> Void,
                            received: @Sendable (LLMResponse) async throws -> Void) async throws -> Completion {
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
        var usesStream = streaming
        var mode = LLMOutputNegotiation.initial(profile, input: input, override: outputMode)
        while true {
            try cancellation.check()
            let grant = try await credentials.resolve(for: profile, settings: settings)
            var wireProfile = profile
            if profile.protocolKind == .openaiCompatible { wireProfile.capabilities.jsonMode = mode }
            let descriptor = try LLMRequestDescriptor.make(profile: wireProfile, input: input, jsonMode: mode != .disabled, streaming: usesStream)
            let request = try grant.request(descriptor)
            let job: GenerationJob
            do { job = try await store.reserveLLMAttempt(ticket, profile: profile, outputTokens: input.maxOutputTokens) }
            catch let failure as LLMFailure { throw failure }
            catch { throw LLMFailure.invalidJob }
            log(.started(attempt: job.attemptCount))
            do {
                var response = try await transport.perform(request, decoder: LLMRequestDescriptor.decoder(for: profile, requiresJSON: input.requiresJSON), progress: progress) { task in
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
                if input.requiresJSON { response.text = try LLMJSONEnvelope.unwrap(response.text) }
                try await received(response)
                try validate(response.text)
                log(.completed(attempts: job.attemptCount))
                let elapsed = started.duration(to: .now).components
                return Completion(response: response, profile: profile, ticket: ticket, attempts: job.attemptCount,
                    reservedOutputTokens: job.reservedOutputTokens ?? 0, elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                    effectiveJSONMode: mode)
            } catch {
                try cancellation.check()
                let failure = diagnostic(error)
                log(.failed(failure))
                let nextMode = input.requiresJSON && LLMOutputNegotiation.automatic(profile) && LLMOutputNegotiation.formatFailure(error)
                    ? LLMOutputNegotiation.next(mode) : nil
                // An iteration owns its ledger and starts a separate immutable attempt for negotiation.
                guard retrying else {
                    if nextMode != nil {
                        if let issue = error as? CreatorRepairIssue {
                            throw CreatorRepairIssue(category: .jsonModeUnsupported, fields: issue.fields)
                        }
                        throw LLMFailure.jsonModeUnsupported
                    }
                    throw error
                }
                let delay: TimeInterval
                if let nextMode { mode = nextMode; delay = 0 }
                else if failure == .streamUnsupported && usesStream { usesStream = false; delay = 0 }
                else { switch failure {
                case .rateLimited(let retryAfter):
                    delay = retryAfter ?? 1
                    guard delay <= 30 else { throw failure }
                case .server: delay = min(2, 0.5 * pow(2, Double(job.attemptCount - 1)))
                default: throw error
                } }
                guard job.attemptCount < min(job.requestBudget, profile.limits.requestBudget),
                      input.maxOutputTokens <= min(job.tokenBudget, profile.limits.tokenBudget) - (job.reservedOutputTokens ?? 0)
                else { throw error }
                log(.retry(attempt: job.attemptCount + 1))
                try await wait(delay)
            }
        }
    }
}
