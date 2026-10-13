import Foundation

#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import WebKit

final class PluginBrowserPackage: @unchecked Sendable {
    static let isSupported = true

    private struct Run: Decodable {
        let script: String
        let id: String
    }

    private let callback: @Sendable (String, String) -> Void
    private var scripts: [String] = []
    private var session: BrowserSession?

    init(callback: @escaping @Sendable (String, String) -> Void) {
        self.callback = callback
    }

    func call(_ operation: String, payload: String) -> String {
        switch operation {
        case "initialize":
            close()
            scripts.removeAll()
        case "addScriptOnLoad":
            scripts.append(payload)
        case "load":
            guard let url = URL(string: payload) else { return "" }
            onMain {
                self.session = BrowserSession(scripts: self.scripts, callback: self.callback)
                self.session?.load(url)
            }
        case "waitTillLoaded":
            let timeout = max(0, Double(payload) ?? 0) / 1_000
            return session?.waitUntilLoaded(timeout: timeout) == true ? "1" : "0"
        case "run":
            guard let run = try? JSONDecoder().decode(Run.self, from: Data(payload.utf8)) else { return "" }
            onMain { self.session?.evaluate(run.script) }
        case "runWithReturn":
            guard let run = try? JSONDecoder().decode(Run.self, from: Data(payload.utf8)) else { return "" }
            onMain { self.session?.evaluate(run.script, returningTo: run.id) }
        default: break
        }
        return ""
    }

    func close() {
        onMain { self.session?.close(); self.session = nil }
    }

    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { work() } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { work() } } }
    }
}

@MainActor
private final class BrowserSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let callback: @Sendable (String, String) -> Void
    private let loaded = DispatchSemaphore(value: 0)
    private var didFinish = false
    private let webView: WKWebView

    init(scripts: [String], callback: @escaping @Sendable (String, String) -> Void) {
        self.callback = callback
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: "window.__GJ = { callback: (id, value) => window.webkit.messageHandlers.hummingbirdBrowser.postMessage({ id: String(id), value: String(value) }) };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        for script in scripts {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(self, name: "hummingbirdBrowser")
        webView.navigationDelegate = self
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    nonisolated func waitUntilLoaded(timeout: TimeInterval) -> Bool {
        loaded.wait(timeout: .now() + timeout) == .success
    }

    func evaluate(_ script: String) { webView.evaluateJavaScript(script) }

    func evaluate(_ script: String, returningTo id: String) {
        webView.evaluateJavaScript(script) { [callback] value, error in
            let result: String
            if let string = value as? String { result = string }
            else if let value, JSONSerialization.isValidJSONObject([value]),
                    let data = try? JSONSerialization.data(withJSONObject: value),
                    let json = String(data: data, encoding: .utf8) { result = json }
            else { result = error?.localizedDescription ?? "" }
            callback(id, result)
        }
    }

    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "hummingbirdBrowser")
        webView.navigationDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { signalLoaded() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { signalLoaded() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { signalLoaded() }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? String else { return }
        callback(id, body["value"] as? String ?? "")
    }

    private func signalLoaded() {
        guard !didFinish else { return }
        didFinish = true
        loaded.signal()
    }
}
#else
final class PluginBrowserPackage: @unchecked Sendable {
    static let isSupported = false
    init(callback: @escaping @Sendable (String, String) -> Void) {}
    func call(_ operation: String, payload: String) -> String { "" }
    func close() {}
}
#endif
