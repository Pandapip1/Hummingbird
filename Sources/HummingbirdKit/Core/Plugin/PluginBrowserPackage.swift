import Foundation

#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import WebKit
import os

/// Grayjay's optional `Browser` package: a hidden page that plugins use as a
/// script host. YouTube loads youtube.com here and calls BotGuard's minter in
/// the page to obtain PO tokens, which a plain JavaScript runtime cannot
/// produce in a form YouTube accepts.
///
/// The page is kept as small and short-lived as minting allows: subresources
/// that do not affect scripts are blocked, media cannot start, data is never
/// persisted, and the page is torn down after a period without plugin calls.
/// The next call transparently reloads it from the URL and scripts the plugin
/// supplied, so plugins observe one long-lived browser as in Grayjay.
final class PluginBrowserPackage: Sendable {
    static let isSupported = true
    static let defaultIdleTimeout: Duration = .seconds(120)
    /// How long a reloaded page may take before plugin scripts can rely on
    /// state its own scripts create (YouTube's minter appears after load).
    static let reloadReadinessTimeout: TimeInterval = 15
    private static let reloadLoadTimeout: TimeInterval = 20

    private struct Run: Decodable {
        let script: String
        let id: String
    }

    private let controller: BrowserController

    init(idleTimeout: Duration = PluginBrowserPackage.defaultIdleTimeout,
         callback: @escaping @Sendable (String, String) -> Void) {
        controller = BrowserController(idleTimeout: idleTimeout, callback: callback)
    }

    func call(_ operation: String, payload: String) -> String {
        switch operation {
        case "initialize":
            onMain { $0.reset() }
        case "addScriptOnLoad":
            onMain { $0.addScript(payload) }
        case "load":
            guard let url = URL(string: payload) else { return "" }
            onMain { $0.load(url) }
        case "waitTillLoaded":
            let timeout = max(0, Double(payload) ?? 0) / 1_000
            guard let session = onMain({ $0.activeSession() }) else { return "0" }
            return session.waitUntilLoaded(timeout: timeout) ? "1" : "0"
        case "run":
            guard let run = try? JSONDecoder().decode(Run.self, from: Data(payload.utf8)) else { return "" }
            evaluate(run.script, callbackID: run.id, returnsValue: false)
        case "runWithReturn":
            guard let run = try? JSONDecoder().decode(Run.self, from: Data(payload.utf8)) else { return "" }
            evaluate(run.script, callbackID: run.id, returnsValue: true)
        default: break
        }
        return ""
    }

    func close() {
        onMain { $0.reset() }
    }

    /// Whether a page currently exists (it does not while torn down for idling).
    var hasLivePage: Bool { onMain { $0.hasSession } }

    /// Runs on the plugin's JavaScript queue, which may block like Grayjay's
    /// `run`, which first waits for the page to be loaded.
    private func evaluate(_ script: String, callbackID: String, returnsValue: Bool) {
        guard let (session, reloaded) = onMain({ $0.sessionForScript() }) else { return }
        if reloaded { _ = session.waitUntilLoaded(timeout: Self.reloadLoadTimeout) }
        let readyBy = reloaded ? Date().addingTimeInterval(Self.reloadReadinessTimeout) : nil
        onMain { _ in session.evaluate(script, callbackID: callbackID, returnsValue: returnsValue, retryUntil: readyBy) }
    }

    private func onMain<T: Sendable>(_ work: @escaping @MainActor (BrowserController) -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work(controller) } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work(controller) } }
    }
}

/// Owns the page and the plugin's description of it. Confined to the main actor.
@MainActor
private final class BrowserController {
    private let idleTimeout: Duration
    private let callback: @Sendable (String, String) -> Void
    private var scripts: [String] = []
    private var url: URL?
    private var session: BrowserSession?
    private var idleTask: Task<Void, Never>?

    nonisolated init(idleTimeout: Duration, callback: @escaping @Sendable (String, String) -> Void) {
        self.idleTimeout = idleTimeout
        self.callback = callback
    }

    func reset() {
        closeSession()
        scripts.removeAll()
        url = nil
    }

    var hasSession: Bool { session != nil }

    func addScript(_ script: String) { scripts.append(script) }

    func load(_ url: URL) {
        closeSession()
        self.url = url
        session = makeSession(url)
    }

    func activeSession() -> BrowserSession? {
        scheduleIdleTeardown()
        return session
    }

    /// The session to run a plugin script in, reloading the page if it was
    /// torn down while idle. The flag reports whether it was reloaded.
    func sessionForScript() -> (BrowserSession, Bool)? {
        scheduleIdleTeardown()
        if let session { return (session, false) }
        guard let url else { return nil }
        let reloaded = makeSession(url)
        session = reloaded
        return (reloaded, true)
    }

    private func makeSession(_ url: URL) -> BrowserSession {
        let session = BrowserSession(scripts: scripts, callback: callback) { [weak self] in
            self?.scheduleIdleTeardown()
        }
        session.load(url)
        scheduleIdleTeardown()
        return session
    }

    private func scheduleIdleTeardown() {
        idleTask?.cancel()
        guard session != nil || url != nil else { return }
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.teardownIfIdle()
        }
    }

    private func teardownIfIdle() {
        guard let session else { return }
        // A plugin may still be waiting for a script result or callback.
        if session.hasPendingWork {
            scheduleIdleTeardown()
            return
        }
        session.close()
        self.session = nil
    }

    private func closeSession() {
        idleTask?.cancel()
        idleTask = nil
        session?.close()
        session = nil
    }
}

@MainActor
private final class BrowserSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let callback: @Sendable (String, String) -> Void
    private let activity: @MainActor () -> Void
    private let loaded = DispatchSemaphore(value: 0)
    private var didFinish = false
    private var pendingEvaluations = 0
    private var pendingCallbacks: Set<String> = []
    private let webView: WKWebView
    /// Signpost intervals: the page load, and each script until its result
    /// or callback arrives (BotGuard minting shows up as `BrowserScript`).
    private var loadSignpost: OSSignpostIntervalState?
    private var scriptSignposts: [String: OSSignpostIntervalState] = [:]

    private let created = Date()

    /// A page still loading, or a script result or callback the plugin is
    /// waiting for. Loading only counts for as long as a plugin would wait.
    var hasPendingWork: Bool {
        pendingEvaluations > 0 || !pendingCallbacks.isEmpty
            || (!didFinish && Date().timeIntervalSince(created) < BrowserSession.maximumLoadWait)
    }
    static let maximumLoadWait: TimeInterval = 60

    init(scripts: [String], callback: @escaping @Sendable (String, String) -> Void,
         activity: @escaping @MainActor () -> Void) {
        self.callback = callback
        self.activity = activity
        let configuration = WKWebViewConfiguration()
        // Each page starts empty and nothing it stores outlives it.
        configuration.websiteDataStore = .nonPersistent()
        // The page is never placed in a window, so WebKit treats it as
        // inactive and by default suspends it: timers stall and script-heavy
        // documents never finish loading. Its scripts must keep running while
        // it exists; the controller bounds how long that is.
        configuration.preferences.inactiveSchedulingPolicy = .none
        // Nothing here is ever watched or heard.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        #if os(iOS) || os(visionOS)
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        configuration.suppressesIncrementalRendering = true
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

    func load(_ url: URL) {
        Task { [weak self] in
            let rules = await SubresourceRules.shared.list()
            guard let self, self.webView.navigationDelegate != nil else { return }
            if let rules { self.webView.configuration.userContentController.add(rules) }
            self.loadSignpost = OSSignposter.plugin.beginInterval(
                "BrowserPageLoad", id: OSSignposter.plugin.makeSignpostID(), "host=\(LogRedaction.redact(url.host ?? "unknown"), privacy: .public)"
            )
            self.webView.load(URLRequest(url: url))
        }
    }

    nonisolated func waitUntilLoaded(timeout: TimeInterval) -> Bool {
        guard loaded.wait(timeout: .now() + timeout) == .success else { return false }
        // Leave the page marked as loaded for any later waiter.
        loaded.signal()
        return true
    }

    /// `retryUntil` is set for a page reloaded after idling: until then a
    /// script that throws is retried, because page state it relies on (such
    /// as YouTube's minter) is created by the page's own scripts after load.
    func evaluate(_ script: String, callbackID: String, returnsValue: Bool, retryUntil: Date?) {
        if !returnsValue { pendingCallbacks.insert(callbackID) }
        if scriptSignposts[callbackID] == nil {
            scriptSignposts[callbackID] = OSSignposter.plugin.beginInterval(
                "BrowserScript", id: OSSignposter.plugin.makeSignpostID(), "returnsValue=\(returnsValue)"
            )
        }
        pendingEvaluations += 1
        activity()
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            self.pendingEvaluations -= 1
            if error != nil, let retryUntil, Date() < retryUntil {
                if !returnsValue { self.pendingCallbacks.remove(callbackID) }
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.evaluate(script, callbackID: callbackID, returnsValue: returnsValue, retryUntil: retryUntil)
                }
                return
            }
            guard returnsValue else {
                // The script reports back through `__GJ.callback`; if it threw,
                // nothing will, so the controller need not wait for it.
                if error != nil {
                    self.pendingCallbacks.remove(callbackID)
                    self.endScriptSignpost(callbackID, outcome: "threw")
                }
                return
            }
            let result: String
            if let string = value as? String { result = string }
            else if let value, JSONSerialization.isValidJSONObject([value]),
                    let data = try? JSONSerialization.data(withJSONObject: value),
                    let json = String(data: data, encoding: .utf8) { result = json }
            else { result = error?.localizedDescription ?? "" }
            self.endScriptSignpost(callbackID, outcome: error == nil ? "ok" : "threw")
            self.callback(callbackID, result)
        }
    }

    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "hummingbirdBrowser")
        webView.navigationDelegate = nil
        pendingCallbacks.removeAll()
        for (id, _) in scriptSignposts { endScriptSignpost(id, outcome: "closed") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { signalLoaded() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { signalLoaded() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { signalLoaded() }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? String else { return }
        pendingCallbacks.remove(id)
        endScriptSignpost(id, outcome: "callback")
        activity()
        callback(id, body["value"] as? String ?? "")
    }

    private func endScriptSignpost(_ id: String, outcome: StaticString) {
        guard let state = scriptSignposts.removeValue(forKey: id) else { return }
        OSSignposter.plugin.endInterval("BrowserScript", state, "\(outcome, privacy: .public)")
    }

    private func signalLoaded() {
        guard !didFinish else { return }
        didFinish = true
        if let loadSignpost {
            OSSignposter.plugin.endInterval("BrowserPageLoad", loadSignpost)
            self.loadSignpost = nil
        }
        loaded.signal()
    }
}

/// Blocks subresources that only affect how the page looks or sounds. Plugin
/// scripts, and the requests they make, are left untouched.
@MainActor
private final class SubresourceRules {
    static let shared = SubresourceRules()
    static let identifier = "app.hummingbird.plugin-browser.subresources.v1"
    static let json = """
        [{"trigger":{"url-filter":".*","resource-type":["image","media","font","style-sheet","svg-document"]},\
        "action":{"type":"block"}}]
        """
    private var compiled: Task<WKContentRuleList?, Never>?

    func list() async -> WKContentRuleList? {
        if let compiled { return await compiled.value }
        let task = Task<WKContentRuleList?, Never> {
            guard let store = WKContentRuleListStore.default() else { return nil }
            do {
                return try await store.compileContentRuleList(
                    forIdentifier: Self.identifier, encodedContentRuleList: Self.json
                )
            } catch {
                PluginLog.browserFailure("content_rules_failed", LogRedaction.text(error.localizedDescription))
                return nil
            }
        }
        compiled = task
        return await task.value
    }
}
#else
final class PluginBrowserPackage: Sendable {
    static let isSupported = false
    init(callback: @escaping @Sendable (String, String) -> Void) {}
    func call(_ operation: String, payload: String) -> String { "" }
    func close() {}
}
#endif
