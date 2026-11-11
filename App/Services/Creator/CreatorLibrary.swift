import Foundation
import WebKit

/// Exact immutable bundle resources. No URL maps to a filesystem path or network request.
@MainActor final class CreatorLibrary: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "wm-lib"
    nonisolated static let hostURL = "wm-lib://host/v1.js"
    struct Asset: Sendable { let folder: String; let file: String; let sha256: String }
    nonisolated static let assets: [String: Asset] = [
        "wm-lib://three/bundle.js": .init(folder: "three", file: "wm-three-r180", sha256: "63f73063f78d79844ff47b189ff8649b6142bfc28dbd4f75c6f6485255d21597"),
        hostURL: .init(folder: "CreatorRuntime", file: "wm-host-v1", sha256: "75b3a42468c875d3aa56293f6437c3bf98be43664ad8be57fc2d55d34463d001"),
        "wm-lib://engines/shader-v1.js": .init(folder: "CreatorRuntime", file: "wm-shader-v1", sha256: "a3fb953e485aecd353986946d510f19e313ac5938e823920875176fe1e628702"),
        "wm-lib://engines/three-v1.js": .init(folder: "CreatorRuntime", file: "wm-three-v1", sha256: "9aa3b065787da643c5af7c0ee3d7d8c3f3ec5a1b5a4d9378cc351f3503fa6ade"),
    ]
    nonisolated private static let cache: Result<[String: Data], Error> = Result {
        try Dictionary(uniqueKeysWithValues: assets.map { key, asset in
            guard let url = Bundle.main.url(forResource: asset.file, withExtension: "js", subdirectory: asset.folder) else { throw CreatorPersistence.Failure.invalidRecord }
            let data = try Data(contentsOf: url)
            guard data.count <= 1024 * 1024, CreatorPersistence.hash(data) == asset.sha256 else { throw CreatorPersistence.Failure.invalidRecord }
            return (key, data)
        })
    }
    nonisolated static func bytes(_ url: String) throws -> Data {
        guard let data = try cache.get()[url] else { throw CreatorPersistence.Failure.invalidRecord }
        return data
    }
    nonisolated static var hostScript: String {
        String(decoding: (try? bytes(hostURL)) ?? Data("throw Error('host_unavailable');".utf8), as: UTF8.self)
    }
    nonisolated static func digest(for source: String) throws -> String? {
        let regex = try NSRegularExpression(pattern: #"wm-lib://[a-zA-Z0-9/._-]+"#)
        let text = source as NSString
        var urls = Set(regex.matches(in: source, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) })
        if try CreatorParameterSchema.read(source) != nil { urls.insert(hostURL) }
        guard !urls.isEmpty else { return nil }
        urls.insert(hostURL)
        return try CreatorTemplate.digest(Dictionary(uniqueKeysWithValues: urls.sorted().map { ($0, try bytes($0)) }))
    }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard task.request.httpMethod == nil || task.request.httpMethod == "GET", let url = task.request.url,
              let data = try? Self.bytes(url.absoluteString) else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        task.didReceive(URLResponse(url: url, mimeType: "application/javascript", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
