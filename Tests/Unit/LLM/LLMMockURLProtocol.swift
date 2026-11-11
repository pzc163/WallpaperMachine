import Foundation

/// Intercepts every request, including unregistered URLs; there is never a network fallback.
final class LLMMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        var hold = false
        var failure: URLError?
        var redirect: URL?
        var responseDelay: TimeInterval = 0
        var chunkInterval: TimeInterval = 0
    }
    final class Route: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply]
        private var captured: [URLRequest] = []
        private var stops = 0
        init(_ replies: [Reply]) { self.replies = replies }
        func replace(_ replies: [Reply]) { lock.withLock { self.replies = replies } }
        var requests: [URLRequest] { lock.withLock { captured } }
        var stopCount: Int { lock.withLock { stops } }
        func stopped() { lock.withLock { stops += 1 } }
        func take(_ request: URLRequest) -> Reply {
            // URLSession can move an HTTP body to a stream before URLProtocol sees it.
            // Capture those bytes here; this test protocol never forwards the request.
            var capturedRequest = request
            if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while bytes.count <= 128 * 1024 {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                capturedRequest.httpBody = bytes
            }
            return lock.withLock {
                captured.append(capturedRequest)
                guard !replies.isEmpty else { return Reply(status: 599) }
                return replies[min(captured.count - 1, replies.count - 1)]
            }
        }
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var routes: [String: Route] = [:]
    }
    private static let registry = Registry()
    private let lock = NSLock()
    private var route: Route?
    private var stopped = false
    private var delivery: Task<Void, Never>?

    static func register(_ route: Route, at url: URL) { registry.lock.withLock { registry.routes[url.absoluteString] = route } }
    static func remove(_ url: URL) { _ = registry.lock.withLock { registry.routes.removeValue(forKey: url.absoluteString) } }
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMMockURLProtocol.self]
        return configuration
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let route = Self.registry.lock.withLock({ Self.registry.routes[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        lock.withLock { self.route = route }
        let reply = route.take(request)
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        if let destination = reply.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            var redirected = request; redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if reply.responseDelay > 0 { try await Task.sleep(for: .seconds(reply.responseDelay)) }
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in reply.chunks {
                    if reply.chunkInterval > 0 { try await Task.sleep(for: .seconds(reply.chunkInterval)) }
                    try Task.checkCancellation()
                    if self.lock.withLock({ self.stopped }) { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                }
                if !reply.hold { self.client?.urlProtocolDidFinishLoading(self) }
            } catch {}
        }
        lock.withLock { if stopped { task.cancel() } else { delivery = task } }
    }

    override func stopLoading() {
        let route = lock.withLock { stopped = true; delivery?.cancel(); delivery = nil; return route }
        route?.stopped()
    }
}
