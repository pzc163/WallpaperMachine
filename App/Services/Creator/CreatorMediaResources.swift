import Foundation
import WebKit

/// Frozen, digest-verified media only. No network, path resolution or native file grant.
@MainActor final class CreatorMediaResources: NSObject, WKURLSchemeHandler {
    static let scheme = "wm-media"
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let data: Data
        let range: Range<Int>
    }
    private weak var resources: CreatorWebResources?
    private var transfers: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(resources: CreatorWebResources) { self.resources = resources }
    static func response(_ request: URLRequest, snapshot: CreatorDraftStore.Snapshot) throws -> Response {
        guard let url = request.url, url.scheme == scheme, url.host == "bundle", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              request.httpMethod == nil || ["GET", "HEAD"].contains(request.httpMethod!),
              let file = snapshot.manifest?.media?.files.first(where: { $0.url == url.absoluteString }),
              let data = snapshot.files[file.path], data.count == file.bytes else { throw URLError(.noPermissionsToReadFile) }
        var headers = ["Content-Type": file.mime, "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]
        var range = 0..<data.count, status = 200
        if let value = request.value(forHTTPHeaderField: "Range") {
            if let selected = byteRange(value, count: data.count) { range = selected; status = 206; headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound-1)/\(data.count)" }
            else { range = 0..<0; status = 416; headers["Content-Range"] = "bytes */\(data.count)" }
        }
        headers["Content-Length"] = String(range.count)
        return Response(status: status, headers: headers, data: data, range: request.httpMethod == "HEAD" ? 0..<0 : range)
    }
    static func byteRange(_ value: String, count: Int) -> Range<Int>? {
        guard count > 0, value.count <= 64, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1] == "*" || parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if parts[0].isEmpty {
            guard let tail = Int(parts[1]), tail > 0 else { return nil }
            return max(0, count-tail)..<count
        }
        guard let start = Int(parts[0]), start < count else { return nil }
        // AVFoundation's custom-scheme loader also uses a trailing * for an open range.
        if parts[1].isEmpty || parts[1] == "*" { return start..<count }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return start..<(min(end, count-1)+1)
    }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        guard transfers.count < 4, let snapshot = resources?.snapshot, let response = try? Self.response(task.request, snapshot: snapshot),
              let url = task.request.url, let headers = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else { resources?.mediaResponses[403, default: 0] += 1; task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        resources?.mediaResponses[response.status, default: 0] += 1
        transfers[key] = Task { [weak self] in
            defer { self?.transfers[key] = nil }
            guard !Task.isCancelled else { return }
            task.didReceive(headers)
            for offset in stride(from: response.range.lowerBound, to: response.range.upperBound, by: 64 * 1024) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                task.didReceive(response.data.subdata(in: offset..<min(offset + 64 * 1024, response.range.upperBound)))
            }
            if !Task.isCancelled { task.didFinish() }
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { transfers.removeValue(forKey: ObjectIdentifier(task))?.cancel() }
}
