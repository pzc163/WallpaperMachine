import Foundation
import WebKit

/// Serves a frozen creator bundle from memory with no file-system grant to WebKit.
@MainActor
final class CreatorWebResources: NSObject, WKURLSchemeHandler {
    static let scheme = "wm-creator"
    static let entryURL = URL(string: "wm-creator://bundle/index.html")!
    var snapshot: CreatorDraftStore.Snapshot?

    // Compile once per process, using the app's test-overridable cache directory.
    // A compilation failure prevents loading. This adds resource filtering, but it
    // is not an arbitrary-code offline boundary; see the S0 isolation probe results.
    private static let compiledRules = Task { @MainActor () throws -> WKContentRuleList in
        let directory = ClientPaths.cacheURL.appendingPathComponent("CreatorWebRules", isDirectory: true)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }.value
        guard let store = WKContentRuleListStore(url: directory) else { throw CreatorTemplate.Failure.invalidPath }
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wm-creator://bundle/index\\.html$"},"action":{"type":"ignore-previous-rules"}}]"#
        guard let rules = try await store.compileContentRuleList(forIdentifier: "creator-offline-v1", encodedContentRuleList: json)
        else { throw CreatorTemplate.Failure.invalidBundle }
        return rules
    }

    static func offlineRules() async throws -> WKContentRuleList { try await compiledRules.value }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url == Self.entryURL,
              task.request.httpMethod == nil || task.request.httpMethod == "GET",
              let data = snapshot?.files["index.html"] else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count,
                                   textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Creator content cannot turn a page interaction into a native dialog or permission prompt.
@MainActor
final class CreatorWebPermissions: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}
