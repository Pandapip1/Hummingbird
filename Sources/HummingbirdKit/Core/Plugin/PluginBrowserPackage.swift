import Foundation
import Crypto

/// What the hidden plugin page may load and send back. Pure functions of the
/// plugin's `PluginNetworkPolicy`, so they are testable without WebKit. The
/// page's connections also go through the plugin's `PluginEgressProxy`, which
/// checks the resolved address of every connection; these rules stop what
/// can be stopped before a connection is attempted.
enum PluginBrowserPolicy {
    /// One script the plugin runs in, or injects into, the page.
    static let maximumScriptBytes = 4 * 1024 * 1024
    /// On-load scripts a plugin may register.
    static let maximumScripts = 64
    /// A value the page hands back to the plugin.
    static let maximumCallbackBytes = 16 * 1024 * 1024
    static let maximumCallbackIDBytes = 256

    /// Whether the page may navigate (any frame) to `url`: http(s) to an
    /// allow-listed host, where a non-public address literal or a local name
    /// also needs the user's approval for that exact host and port; and
    /// `about:blank`/`about:srcdoc` and `data:` documents, which load nothing
    /// from the network themselves. Everything else (file:, custom schemes,
    /// blob: frames, ...) is refused.
    static func allowsNavigation(to url: URL?, policy: PluginNetworkPolicy) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "about":
            let target = url.absoluteString.lowercased()
            return target == "about:blank" || target == "about:srcdoc"
        case "data":
            return true
        case "http", "https":
            guard let rawHost = url.host(percentEncoded: false), !rawHost.isEmpty else { return false }
            let host = PluginNetworkPolicy.normalizedHost(rawHost)
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            guard policy.allowListed(host: host, port: port) else { return false }
            if let literal = IPAddress(literal: host) {
                switch literal.scope {
                case .public: return true
                case .metadata: return false
                case .nonPublic: return policy.approvals.contains { $0.permits(host: host, port: port, address: literal) }
                }
            }
            if AddressClassifier.isLocalName(host) {
                return policy.approvals.contains { $0.host == host && $0.port == port }
            }
            return true
        default:
            return false
        }
    }

    /// The WebKit content rules for the page, as JSON. Without "everywhere"
    /// every subresource is blocked except those on allow-listed hosts.
    /// Either way, address literals in non-public ranges and local names are
    /// blocked unless the user approved that exact host and port, and so is
    /// everything that only affects how the page looks or sounds.
    static func contentRules(for policy: PluginNetworkPolicy) -> String {
        var rules: [[String: Any]] = []
        func block(_ filter: String, types: [String]? = nil) {
            var trigger: [String: Any] = ["url-filter": filter]
            if let types { trigger["resource-type"] = types }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        func allow(_ filter: String) {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]])
        }
        func hostPattern(_ host: String) -> String {
            guard let literal = IPAddress(literal: host), !literal.isIPv4 else { return regexEscape(host) }
            return #"\["# + regexEscape(host) + #"\]"#
        }
        let everywhere = policy.entries.contains { $0.kind == .everywhere }
        if !everywhere {
            block(".*")
            // Documents and workers the page makes itself load nothing from the network.
            allow("^data:")
            allow("^blob:")
            allow("^about:")
            for entry in policy.entries {
                let target: (host: String, subdomains: Bool)
                switch entry.kind {
                case .everywhere: continue
                case .exact(let h): target = (h, false)
                case .domain(let d): target = (d, true)
                }
                let prefix = target.subdomains ? #"([^/@]*\.)?"# : ""
                let port = entry.port.map { ":\($0)" } ?? "(:[0-9]+)?"
                for scheme in ["https?", "wss?"] {
                    allow("^\(scheme)://\(prefix)\(hostPattern(target.host))\(port)/")
                }
            }
        }
        // Non-public address literals and local names, whatever the allow-list
        // says. Each range names the first two octets (a few cover a little
        // more than the reserved /24, which only over-blocks literal IPs).
        let authority = "^[a-z]+://([^/@]*@)?"
        let ranges = [
            #"127\.[0-9]+\."#, #"10\.[0-9]+\."#, #"0\.[0-9]+\."#, #"192\.168\."#, #"192\.0\."#,
            #"172\.1[6-9]\."#, #"172\.2[0-9]\."#, #"172\.3[01]\."#, #"169\.254\."#,
            #"100\.6[4-9]\."#, #"100\.[7-9][0-9]\."#, #"100\.1[01][0-9]\."#, #"100\.12[0-7]\."#,
            #"198\.1[89]\."#, #"198\.51\."#, #"203\.0\."#, #"22[4-9]\.[0-9]+\."#, #"2[3-5][0-9]\.[0-9]+\."#,
        ]
        for range in ranges { block(authority + range + #"[0-9]+\.[0-9]+[:/]"#) }
        block(authority + #"\["#)
        block(authority + "localhost[:/]")
        block(authority + #"[^/:@]*\.localhost[:/]"#)
        block(authority + #"[^/:@]*\.local[:/]"#)
        block(authority + #"[^/:@]*\.home\.arpa[:/]"#)
        block(authority + #"[^/:@]*\.internal[:/]"#)
        // What the user approved by exact host and port (the proxy still
        // checks the address each connection resolves to).
        for approval in policy.approvals where policy.allowListed(host: approval.host, port: approval.port) {
            for scheme in ["https?", "wss?"] {
                allow("^\(scheme)://\(hostPattern(approval.host)):\(approval.port)/")
                if approval.port == 80 || approval.port == 443 { allow("^\(scheme)://\(hostPattern(approval.host))/") }
            }
        }
        // Cosmetic: nothing on this page is ever seen or heard.
        block(".*", types: ["image", "media", "font", "style-sheet", "svg-document"])
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A stable identifier for a compiled rule list.
    static func ruleListIdentifier(for json: String) -> String {
        let digest = SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "app.hummingbird.plugin-browser.rules.v2.\(digest)"
    }

    /// Escapes text for WebKit's content-rule regular expression subset.
    static func regexEscape(_ text: String) -> String {
        var out = ""
        for c in text {
            if #".[]()*+?^$\|{}"#.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Whether a plugin script (on-load or run) is small enough to accept.
    static func acceptsScript(_ script: String) -> Bool { script.utf8.count <= maximumScriptBytes }

    /// A page-supplied callback: nil when its id is unusable, an empty value
    /// when the value is too large to hand the plugin.
    static func boundedCallback(id: String, value: String) -> (id: String, value: String)? {
        guard !id.isEmpty, id.utf8.count <= maximumCallbackIDBytes else { return nil }
        guard value.utf8.count <= maximumCallbackBytes else { return (id, "") }
        return (id, value)
    }
}

#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import WebKit
import os
#if canImport(Network)
import Network
#endif

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
///
/// Containment: the page has its own non-persistent store whose connections
/// go through the plugin's `PluginEgressProxy` (every connection's resolved
/// address is checked, and the connection goes to exactly that address);
/// frames may only navigate where `PluginBrowserPolicy` allows; subresources
/// are limited by per-plugin content rules; it can open no windows and start
/// no downloads; scripts and callback values are size-bounded.
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

    /// `proxy` is the plugin's egress proxy; every connection the page makes
    /// goes through it. Nil only where the platform cannot route WebKit
    /// through a proxy, in which case navigation and content rules are the
    /// only network bounds (see Documentation/PluginSecurity.md).
    init(policy: PluginNetworkPolicy, proxy: PluginEgressProxy?,
         idleTimeout: Duration = PluginBrowserPackage.defaultIdleTimeout,
         callback: @escaping @Sendable (String, String) -> Void) {
        controller = BrowserController(policy: policy, proxy: proxy, idleTimeout: idleTimeout, callback: callback)
    }

    func call(_ operation: String, payload: String) -> String {
        // A run payload is a script plus a short id.
        guard payload.utf8.count <= PluginBrowserPolicy.maximumScriptBytes + 1_024 else { return "" }
        switch operation {
        case "initialize":
            onMain { $0.reset() }
        case "addScriptOnLoad":
            guard PluginBrowserPolicy.acceptsScript(payload) else { return "" }
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
    private let policy: PluginNetworkPolicy
    private let proxy: PluginEgressProxy?
    private let idleTimeout: Duration
    private let callback: @Sendable (String, String) -> Void
    private var scripts: [String] = []
    private var url: URL?
    private var session: BrowserSession?
    private var idleTask: Task<Void, Never>?

    nonisolated init(policy: PluginNetworkPolicy, proxy: PluginEgressProxy?, idleTimeout: Duration,
                     callback: @escaping @Sendable (String, String) -> Void) {
        self.policy = policy
        self.proxy = proxy
        self.idleTimeout = idleTimeout
        self.callback = callback
    }

    func reset() {
        closeSession()
        scripts.removeAll()
        url = nil
    }

    var hasSession: Bool { session != nil }

    func addScript(_ script: String) {
        guard scripts.count < PluginBrowserPolicy.maximumScripts else { return }
        scripts.append(script)
    }

    /// Loads `url` if the plugin may navigate there; otherwise the previous
    /// page is discarded and nothing loads (`waitTillLoaded` then reports false).
    func load(_ url: URL) {
        closeSession()
        guard PluginBrowserPolicy.allowsNavigation(to: url, policy: policy) else {
            self.url = nil
            PluginLog.browserFailure("navigation_refused", LogRedaction.text("load \(url.absoluteString)"))
            return
        }
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
        let session = BrowserSession(scripts: scripts, policy: policy, proxy: proxy, callback: callback) { [weak self] in
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
private final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let policy: PluginNetworkPolicy
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

    init(scripts: [String], policy: PluginNetworkPolicy, proxy: PluginEgressProxy?,
         callback: @escaping @Sendable (String, String) -> Void,
         activity: @escaping @MainActor () -> Void) {
        self.policy = policy
        self.callback = callback
        self.activity = activity
        let configuration = WKWebViewConfiguration()
        // Each page starts empty and nothing it stores outlives it.
        let store = WKWebsiteDataStore.nonPersistent()
        // Every connection the page makes goes through the plugin's egress
        // proxy, which checks the address it resolves to and connects there
        // only; there is no fallback to a direct connection.
        #if canImport(Network)
        if let proxy { store.proxyConfigurations = [proxy.proxyConfiguration] }
        #endif
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
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
        webView.uiDelegate = self
    }

    /// Loads only once the plugin's content rules are in place; if they
    /// cannot be compiled the page does not load at all.
    func load(_ url: URL) {
        let json = PluginBrowserPolicy.contentRules(for: policy)
        Task { [weak self] in
            let rules = await ContentRules.shared.list(json: json)
            guard let self, self.webView.navigationDelegate != nil else { return }
            guard let rules else {
                self.signalLoaded()
                return
            }
            self.webView.configuration.userContentController.add(rules)
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
            guard let bounded = PluginBrowserPolicy.boundedCallback(id: callbackID, value: result) else { return }
            self.callback(bounded.id, bounded.value)
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

    /// Every frame's navigations, including redirects: only where the plugin
    /// may go, and never a download.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = !navigationAction.shouldPerformDownload
            && PluginBrowserPolicy.allowsNavigation(to: navigationAction.request.url, policy: policy)
        if !allowed {
            PluginLog.browserFailure("navigation_refused", LogRedaction.text(navigationAction.request.url?.absoluteString ?? ""))
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// A response the page cannot display would become a download.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    /// The page can open no windows.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? String,
              let bounded = PluginBrowserPolicy.boundedCallback(id: id, value: body["value"] as? String ?? "") else { return }
        pendingCallbacks.remove(bounded.id)
        endScriptSignpost(bounded.id, outcome: "callback")
        activity()
        callback(bounded.id, bounded.value)
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

/// Compiles each plugin's content rules (`PluginBrowserPolicy.contentRules`)
/// once per distinct rule set.
@MainActor
private final class ContentRules {
    static let shared = ContentRules()
    private var compiled: [String: Task<WKContentRuleList?, Never>] = [:]

    func list(json: String) async -> WKContentRuleList? {
        let identifier = PluginBrowserPolicy.ruleListIdentifier(for: json)
        if let compiled = compiled[identifier] { return await compiled.value }
        let task = Task<WKContentRuleList?, Never> {
            guard let store = WKContentRuleListStore.default() else { return nil }
            do {
                return try await store.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: json
                )
            } catch {
                PluginLog.browserFailure("content_rules_failed", LogRedaction.text(error.localizedDescription))
                return nil
            }
        }
        compiled[identifier] = task
        return await task.value
    }
}
#else
final class PluginBrowserPackage: Sendable {
    static let isSupported = false
    init(policy: PluginNetworkPolicy, proxy: PluginEgressProxy?,
         idleTimeout: Duration = .seconds(120),
         callback: @escaping @Sendable (String, String) -> Void) {}
    func call(_ operation: String, payload: String) -> String { "" }
    func close() {}
}
#endif
