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
    private var outcome: Result<LLMResponse, LLMFailure>?
    private var continuation: CheckedContinuation<LLMResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var launch: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(request: URLRequest, decoder: any LLMProtocolCodec, configuration: URLSessionConfiguration, limits: LLMStreamTransport.Limits) {
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
                configuration.timeoutIntervalForRequest = limits.timeout
                configuration.timeoutIntervalForResource = limits.timeout
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var timedRequest = request
                timedRequest.timeoutInterval = limits.timeout
                let task = session.dataTask(with: timedRequest)
                let accepted = lock.withLock { () -> Bool in
                    guard outcome == nil else { return false }
                    self.session = session; self.task = task
                    launch = Task {
                        do { try Task.checkCancellation(); try await start(task) }
                        catch { self.finish(.failure(LLMFailure.sanitized(error))) }
                    }
                    deadline = Task {
                        do { try await Task.sleep(for: .seconds(limits.timeout)); self.finish(.failure(.timeout)) }
                        catch {}
                    }
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
            if http.statusCode == 400 { return (true, nil) }
            if let failure = LLMHTTPPolicy.failure(for: http) { return (false, failure) }
            guard http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream"
            else { return (false, .protocolViolation) }
            return (true, nil)
        }
        if let failure = result.1 { finish(.failure(failure)) }
        completionHandler(result.0 ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failure: LLMFailure? = lock.withLock {
            guard outcome == nil else { return nil }
            guard let responseCode else { return .protocolViolation }
            if responseCode == 400 {
                guard data.count <= 4096 - errorBody.count else { return .http(400) }
                errorBody.append(data); return nil
            }
            do { for event in try parser.append(data) { try decoder.consume(event) }; return nil }
            catch { return LLMFailure.sanitized(error) }
        }
        if let failure { finish(.failure(failure)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<LLMResponse, LLMFailure>? = lock.withLock {
            guard outcome == nil else { return nil }
            if let error { return .failure(LLMFailure.sanitized(error)) }
            if responseCode == 400 { return .failure(LLMHTTPPolicy.unsupportedJSONMode(errorBody) ? .jsonModeUnsupported : .http(400)) }
            guard responseCode != nil else { return .failure(.network) }
            do { try parser.finish(); return .success(try decoder.finish()) }
            catch { return .failure(LLMFailure.sanitized(error)) }
        }
        if let result { finish(result) }
    }
    private func finish(_ result: Result<LLMResponse, LLMFailure>) {
        let cleanup = lock.withLock { () -> (CheckedContinuation<LLMResponse, Error>?, URLSession?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard outcome == nil else { return nil }
            outcome = result
            let values = (continuation, session, launch, deadline)
            continuation = nil; session = nil; task = nil; launch = nil; deadline = nil; errorBody.removeAll()
            return values
        }
        guard let cleanup else { return }
        cleanup.2?.cancel(); cleanup.3?.cancel(); cleanup.1?.invalidateAndCancel()
        cleanup.0?.resume(with: result.mapError { $0 as Error })
    }
}
