import Foundation

/// All decoder state is locked; a terminal result wins once, including redirect/response races.
final class LLMStreamOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let limits: LLMStreamTransport.Limits
    private let lock = NSLock()
    private var parser: SSEParser
    private var decoder: any LLMProtocolCodec
    private var responseCode: Int?
    private var errorBody = Data()
    private var jsonBody = Data()
    private var isJSON = false
    private var outcome: Result<LLMResponse, LLMFailure>?
    private var continuation: CheckedContinuation<LLMResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var launch: Task<Void, Never>?
    private let progress: @Sendable (LLMStreamProgress) -> Void
    private var tracker: LLMDeadlineTracker?
    private var lastEmission: ContinuousClock.Instant?
    private var lastProgress = LLMStreamProgress()
    private var activityDeadline: Task<Void, Never>?

    init(request: URLRequest, decoder: any LLMProtocolCodec, configuration: URLSessionConfiguration, limits: LLMStreamTransport.Limits,
         progress: @escaping @Sendable (LLMStreamProgress) -> Void = { _ in }) {
        self.progress = progress
        self.request = request; self.decoder = decoder; self.limits = limits
        parser = SSEParser(maximumBytes: limits.maximumBytes, maximumEventBytes: limits.maximumEventBytes)
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }
    func run(start: @escaping @Sendable (URLSessionDataTask) async throws -> Void) async throws -> LLMResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let previous = lock.withLock { () -> Result<LLMResponse, LLMFailure>? in
                    if outcome == nil { self.continuation = continuation }
                    return outcome
                }
                if let previous { continuation.resume(with: previous.mapError { $0 as Error }); return }
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.httpAdditionalHeaders = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.waitsForConnectivity = false
                // Native phase deadlines below own the policy. URLSession must not cut off prefill.
                configuration.timeoutIntervalForRequest = max(limits.idleTimeout, limits.firstResponseTimeout, limits.firstContentTimeout ?? 0)
                configuration.timeoutIntervalForResource = limits.timeout
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var timedRequest = request
                timedRequest.timeoutInterval = configuration.timeoutIntervalForRequest
                let task = session.dataTask(with: timedRequest)
                let accepted = lock.withLock { () -> Bool in
                    guard outcome == nil else { return false }
                    self.session = session; self.task = task
                    launch = Task {
                        do { try Task.checkCancellation(); try await start(task) }
                        catch { self.finish(.failure(LLMFailure.sanitized(error))) }
                    }
                    tracker = .init(began: ProcessInfo.processInfo.systemUptime, limits: limits)
                    restartDeadline()
                    return true
                }
                if !accepted { session.invalidateAndCancel() }
            }
        } onCancel: { self.finish(.failure(.cancelled)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // These are fixed POST endpoints. S1.2 rejects even same-origin redirects rather than
        // changing methods/endpoints or forwarding headers before another configuration check.
        finish(.failure(.redirectRejected))
        completionHandler(nil)
        task.cancel()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            finish(.failure(.unauthorized))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let result: (Bool, LLMFailure?) = lock.withLock {
            guard outcome == nil else { return (false, nil) }
            guard responseCode == nil, let http = response as? HTTPURLResponse,
                  http.url == request.url else { return (false, .protocolViolation) }
            responseCode = http.statusCode
            tracker?.response(at: ProcessInfo.processInfo.systemUptime)
            restartDeadline()
            if [400, 422].contains(http.statusCode) { return (true, nil) }
            if let failure = LLMHTTPPolicy.failure(for: http) { return (false, failure) }
            let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            isJSON = mime == "application/json" && decoder.acceptsJSON
            guard mime == "text/event-stream" || isJSON else { return (false, .protocolViolation) }
            return (true, nil)
        }
        if let failure = result.1 { finish(.failure(failure)) }
        if result.0 { progress(.init(phase: .waiting)) }
        completionHandler(result.0 ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var update: LLMStreamProgress?
        let failure: LLMFailure? = lock.withLock {
            guard outcome == nil else { return nil }
            guard let responseCode else { return .protocolViolation }
            if [400, 422].contains(responseCode) {
                guard data.count <= 4096 - errorBody.count else { return .http(responseCode) }
                errorBody.append(data); return nil
            }
            if isJSON {
                guard data.count <= limits.maximumBytes - jsonBody.count else { return .streamLimit }
                receivedActivity(bytes: data.count, value: nil, effective: !data.isEmpty)
                jsonBody.append(data); return nil
            }
            do {
                for event in try parser.append(data) { try decoder.consume(event) }
                let next = decoder.progress, now = ContinuousClock.now
                receivedActivity(bytes: data.count, value: next, effective: next.characters > 0 || !next.reasoning.isEmpty)
                if (next.phase != lastProgress.phase || lastEmission.map { $0.duration(to: now) >= .milliseconds(200) } ?? true) && next != lastProgress {
                    lastEmission = now; lastProgress = next; update = next
                }
                return nil
            }
            catch { return LLMFailure.sanitized(error) }
        }
        if let failure {
            progress(lock.withLock { decoder.progress })
            finish(.failure(failure))
        }
        else if let update { progress(update) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<LLMResponse, LLMFailure>? = lock.withLock {
            guard outcome == nil else { return nil }
            if let error {
                if (error as? URLError)?.code == .timedOut,
                   let evidence = tracker?.failure(at: ProcessInfo.processInfo.systemUptime) { return .failure(.deadline(evidence)) }
                return .failure(LLMFailure.sanitized(error))
            }
            if let responseCode, [400, 422].contains(responseCode) { return .failure(LLMHTTPPolicy.rejectedOutputLimit(errorBody) ? .contextWindow : LLMHTTPPolicy.unsupportedUsage(errorBody) ? .usageUnsupported : LLMHTTPPolicy.unsupportedJSONMode(errorBody) ? .jsonModeUnsupported : LLMHTTPPolicy.unsupportedStream(errorBody) ? .streamUnsupported : .http(responseCode)) }
            guard responseCode != nil else { return .failure(.network) }
            do {
                if isJSON { try decoder.consumeJSON(jsonBody) } else { try parser.finish() }
                return .success(try decoder.finish())
            }
            catch { return .failure(LLMFailure.sanitized(error)) }
        }
        if let result {
            progress(lock.withLock { decoder.progress })
            finish(result)
        }
    }
    // Called under lock. Heartbeats count as activity, never as the first useful model output.
    private func receivedActivity(bytes: Int, value: LLMStreamProgress?, effective: Bool) {
        let wasWaiting = tracker?.contentAt == nil
        tracker?.received(bytes: bytes, characters: value?.characters ?? 0, effectiveContent: effective, at: ProcessInfo.processInfo.systemUptime)
        if wasWaiting && tracker?.contentAt != nil { restartDeadline() }
    }
    private func restartDeadline() {
        activityDeadline?.cancel()
        activityDeadline = Task { await self.watchActivity() }
    }
    private func watchActivity() async {
        while !Task.isCancelled {
            let next = lock.withLock { () -> TimeInterval? in
                guard outcome == nil else { return nil }
                return tracker?.nextDeadline
            }
            guard let next else { return }
            do { try await Task.sleep(for: .seconds(max(0, next - ProcessInfo.processInfo.systemUptime))); try Task.checkCancellation() } catch { return }
            let failure = lock.withLock { () -> LLMFailure? in
                guard outcome == nil else { return nil }
                return tracker?.failure(at: ProcessInfo.processInfo.systemUptime).map { .deadline($0) }
            }
            if let failure { finish(.failure(failure)); return }
        }
    }
    private func finish(_ result: Result<LLMResponse, LLMFailure>) {
        var terminalProgress: LLMStreamProgress?
        let cleanup = lock.withLock { () -> (CheckedContinuation<LLMResponse, Error>?, URLSession?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard outcome == nil else { return nil }
            outcome = result
            terminalProgress = decoder.progress
            let values = (continuation, session, launch, activityDeadline)
            continuation = nil; session = nil; task = nil; launch = nil; activityDeadline = nil; errorBody.removeAll(); jsonBody.removeAll()
            return values
        }
        guard let cleanup else { return }
        if case .failure = result, let terminalProgress { progress(terminalProgress) }
        cleanup.2?.cancel(); cleanup.3?.cancel(); cleanup.1?.invalidateAndCancel()
        cleanup.0?.resume(with: result.mapError { $0 as Error })
    }
}
