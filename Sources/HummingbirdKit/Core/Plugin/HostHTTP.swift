import Foundation
import os
import Synchronization

private final class HTTPBatchState: @unchecked Sendable {
    let requests: [[String: Any]]
    private var results: [[String: Any]]
    private let lock = NSLock()

    init(requests: [[String: Any]]) {
        self.requests = requests
        results = .init(repeating: [:], count: requests.count)
    }

    func store(_ result: [String: Any], at index: Int) {
        lock.withLock { results[index] = result }
    }

    func snapshot() -> [[String: Any]] { lock.withLock { results } }
}

private final class LocalNetworkDecision: Sendable {
    let allowed = Mutex(false)
}

/// Native side of the plugin `http` package. The JS wrapper (prelude.js) batches requests and calls `execute`
/// with a JSON array; this class performs them (optionally in parallel) and returns a JSON array of responses.
///
/// Containment (Documentation/PluginSecurity.md): every request and redirect hop is checked by the plugin's
/// `PluginNetworkPolicy` (http(s) only, allow-list, one resolution, non-public addresses only when the user
/// approved that exact host:port and address) and, where the platform allows, connects through the plugin's
/// `PluginEgressProxy`, which connects to exactly the address it checked. The session carries no ambient
/// credentials: no cookie store, cache, credential storage or client certificates. Batches, bodies, headers,
/// concurrency and request rate are bounded per plugin.
final class HostHTTP: NSObject, @unchecked Sendable {
    struct ClientState {
        var withAuth: Bool
        /// Cookies from stored auth / captcha data and from responses on an authenticated client.
        var currentCookies: [String: [String: String]]
        /// Cookies learned from responses on unauthenticated clients.
        var otherCookies: [String: [String: String]] = [:]
    }

    static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; rv:91.0) Gecko/20100101 Firefox/91.0"
    private static let visibleHeaders: Set<String> = [
        "content-type", "date", "content-length", "last-modified", "etag", "cache-control",
        "content-encoding", "content-disposition", "connection", "retry-after",
    ]
    /// Headers a plugin may not set: they belong to the transport or would
    /// smuggle a second request or a proxy credential.
    private static let forbiddenRequestHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "proxy-authorization", "proxy-connection",
        "keep-alive", "upgrade", "te", "trailer", "expect",
    ]
    private static let maximumAutomaticRetryDelay: TimeInterval = 30
    private static let maximumRetryAfter: TimeInterval = 31_536_000

    let config: PluginConfig
    let policy: PluginNetworkPolicy
    private let auth: SourceAuth?
    private let captcha: SourceAuth?
    private var clients: [String: ClientState] = [:]
    private let lock = NSLock()
    private let session: URLSession
    /// The proxy plugin connections go through; nil when a test injected its own session,
    /// or on platforms whose URL loading ignores proxies.
    let proxy: PluginEgressProxy?
    /// Set when the proxy could not start where it is required: every request then fails.
    private let startupFailure: String?
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private var rateLimits: [String: (until: Date, failures: Int)] = [:]
    private var rateLimitGenerations: [String: UInt64] = [:]
    private let localNetworkAccess: (@Sendable (URL) async -> Bool)?
    private let inFlight = DispatchSemaphore(value: PluginLimits.maximumConcurrentRequests)
    private var requestBudget = TokenBucket(rate: PluginLimits.requestsPerSecond, burst: PluginLimits.requestBurst)

    init(
        config: PluginConfig,
        auth: SourceAuth?,
        captcha: SourceAuth?,
        policy: PluginNetworkPolicy? = nil,
        session: URLSession? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        localNetworkAccess: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.config = config
        let policy = policy ?? PluginNetworkPolicy(config: config, approvals: [])
        self.policy = policy
        self.auth = auth
        self.captcha = captcha
        if let session {
            self.session = session
            proxy = nil
            startupFailure = nil
        } else {
            let cfg = Self.containedConfiguration()
            var proxy: PluginEgressProxy?
            var failure: String?
            if PluginEgressProxy.pinsURLSessionConnections {
                do {
                    let started = try PluginEgressProxy.start(policy: policy)
                    started.apply(to: cfg)
                    proxy = started
                } catch {
                    failure = "The plugin network guard could not start: \(error.localizedDescription)"
                }
            }
            self.proxy = proxy
            startupFailure = failure
            self.session = URLSession(configuration: cfg)
        }
        self.now = now
        self.sleep = sleep
        self.localNetworkAccess = localNetworkAccess
        super.init()
        clients["default-anon"] = makeState(withAuth: false)
        clients["default-auth"] = makeState(withAuth: true)
    }

    deinit {
        proxy?.close()
    }

    /// A session configuration with no ambient credentials or shared state.
    static func containedConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.urlCredentialStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        return cfg
    }

    func close() {
        session.invalidateAndCancel()
        proxy?.close()
    }

    private func makeState(withAuth: Bool) -> ClientState {
        var current: [String: [String: String]] = [:]
        if withAuth, let auth {
            for (d, m) in auth.cookieMap { current[d, default: [:]].merge(m) { _, new in new } }
        }
        if let captcha {
            for (d, m) in captcha.cookieMap { current[d, default: [:]].merge(m) { _, new in new } }
        }
        return ClientState(withAuth: withAuth, currentCookies: current)
    }

    /// Whether the plugin may reach `url`: the policy (allow-list, resolution,
    /// approvals), then the system local-network permission gate for an
    /// approved local destination. Plugin requests run on the plugin's own
    /// worker, so waiting here for the gate (on the main actor) is safe.
    func mayReach(_ url: URL) -> Result<AuthorizedRequest, NetworkDenial> {
        let authorized = policy.authorize(url)
        guard case .success(let request) = authorized else { return authorized }
        guard let localNetworkAccess, Self.needsSystemPermission(request.destination.scope) else { return authorized }
        dispatchPrecondition(condition: .notOnQueue(.main))
        let decision = LocalNetworkDecision()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let allowed = await localNetworkAccess(url)
            decision.allowed.withLock { $0 = allowed }
            semaphore.signal()
        }
        semaphore.wait()
        guard decision.allowed.withLock({ $0 }) else {
            return .failure(.localNotApproved(host: request.destination.host, port: request.destination.port,
                                              address: request.destination.address.description))
        }
        return authorized
    }

    /// Destinations the operating system's local-network permission covers (not loopback).
    private static func needsSystemPermission(_ scope: AddressScope) -> Bool {
        if case .nonPublic(let kind) = scope { return kind != .loopback && kind != .unspecified }
        return false
    }

    // MARK: entry point

    /// Runs a batch. `deadline` is the plugin call's: no request outlives it.
    func execute(json: String, parallel: Bool, deadline: Date = .distantFuture, isCancelled: @escaping @Sendable () -> Bool = { false }) -> String {
        guard let data = json.data(using: .utf8),
              let requests = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return "[]" }
        guard requests.count <= PluginLimits.maximumBatchRequests else {
            let error: [String: Any] = ["error": "A batch may hold at most \(PluginLimits.maximumBatchRequests) requests.",
                                        "errorType": "ScriptImplementationException"]
            return Self.json(Array(repeating: error, count: requests.count))
        }
        let batch = HTTPBatchState(requests: requests)
        let runOne: @Sendable (Int) -> Void = { [self, batch] i in
            batch.store(run(batch.requests[i], deadline: deadline, isCancelled: isCancelled), at: i)
        }
        if parallel && requests.count > 1 {
            let group = DispatchGroup()
            for i in 0..<requests.count {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { runOne(i); group.leave() }
            }
            group.wait()
        } else {
            for i in 0..<requests.count { runOne(i) }
        }
        return Self.json(batch.snapshot())
    }

    private static func json(_ value: [[String: Any]]) -> String {
        let out = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("[]".utf8)
        return String(decoding: out, as: UTF8.self)
    }

    private static func denied(_ denial: NetworkDenial) -> [String: Any] {
        ["error": denial.localizedDescription, "errorType": "ScriptImplementationException"]
    }

    // MARK: one request

    private func run(_ req: [String: Any], deadline: Date, isCancelled: @Sendable () -> Bool) -> [String: Any] {
        if let control = req["control"] as? String {
            handleControl(control, req)
            return ["code": 200]
        }
        if let startupFailure { return ["error": startupFailure] }
        guard !isCancelled(), Date() < deadline else { return ["error": "The plugin call was cancelled or timed out"] }
        guard let method = (req["method"] as? String)?.uppercased(),
              method.range(of: #"^[A-Z]{1,16}$"#, options: .regularExpression) != nil,
              let urlString = req["url"] as? String,
              urlString.utf8.count <= PluginLimits.maximumURLLength,
              let url = URL(string: urlString) else { return ["error": "Invalid request URL"] }

        let authorized: AuthorizedRequest
        switch mayReach(url) {
        case .success(let request): authorized = request
        case .failure(let denial): return Self.denied(denial)
        }
        let host = authorized.destination.host

        let clientId = req["clientId"] as? String ?? "default-anon"
        let useAuth = req["useAuth"] as? Bool ?? false
        let applyCookies = req["applyCookies"] as? Bool ?? true
        let updateCookies = req["updateCookies"] as? Bool ?? true
        let allowNewCookies = req["allowNewCookies"] as? Bool ?? true
        let wantsBytes = req["bytes"] as? Bool ?? false

        var request = authorized.urlRequest
        request.httpMethod = method
        var timeout: TimeInterval = 30
        if let ms = req["timeoutMs"] as? Double, ms > 0 { timeout = min(timeout, ms / 1000) }
        timeout = min(timeout, max(0.5, deadline.timeIntervalSinceNow))
        request.timeoutInterval = timeout

        var headers: [String: String] = [:]
        if let h = req["headers"] as? [String: Any] {
            guard h.count <= PluginLimits.maximumHeaderCount else { return ["error": "Too many request headers"] }
            for (k, v) in h {
                let value = "\(v)"
                guard k.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$"#, options: .regularExpression) != nil,
                      !Self.forbiddenRequestHeaders.contains(k.lowercased()),
                      value.utf8.count <= PluginLimits.maximumHeaderValueBytes,
                      !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { continue }
                headers[k] = value
            }
        }
        func has(_ name: String) -> Bool { headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }

        if useAuth, let auth {
            for (domain, hs) in auth.headers where domainMatches(host: host, domain: domain) {
                for (k, v) in hs where !has(k) { headers[k] = v }
            }
        }
        if applyCookies {
            let cookie = cookieHeader(clientId: clientId, host: host)
            if !cookie.isEmpty {
                if let existing = headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }) {
                    headers[existing.key] = existing.value + "; " + cookie
                } else { headers["Cookie"] = cookie }
            }
        }
        if !has("User-Agent") { headers["User-Agent"] = Self.defaultUserAgent }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        if let body = req["body"] as? [String: Any] {
            if let text = body["text"] as? String {
                guard text.utf8.count <= PluginLimits.maximumRequestBodyBytes else { return ["error": "Request body too large"] }
                request.httpBody = Data(text.utf8)
                if !has("Content-Type") { request.setValue("text/plain", forHTTPHeaderField: "Content-Type") }
            }
            else if let b64 = body["b64"] as? String {
                guard b64.utf8.count <= PluginLimits.maximumRequestBodyBytes * 4 / 3 + 4 else { return ["error": "Request body too large"] }
                request.httpBody = Data(base64Encoded: b64)
            }
        }

        if let remaining = rateLimitRemaining(for: host), remaining > 0 {
            guard remaining <= Self.maximumAutomaticRetryDelay, now().addingTimeInterval(remaining) < deadline else {
                return rateLimitedResponse(url: urlString, retryAfter: remaining, wantsBytes: wantsBytes)
            }
            sleep(remaining)
        }

        // The plugin's own request budget: rate, then concurrency, both bounded by the call deadline.
        let wait = lock.withLock { requestBudget.take() }
        if wait > 0 {
            guard Date().addingTimeInterval(wait) < deadline else { return ["error": "The plugin is making too many requests"] }
            Thread.sleep(forTimeInterval: wait)
        }
        guard inFlight.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            return ["error": "The plugin is making too many concurrent requests"]
        }
        defer { inFlight.signal() }

        let mayRetry = ["GET", "HEAD", "OPTIONS"].contains(method)
        var retryCount = 0
        while true {
            let generation = rateLimitGeneration(for: host)
            let result = perform(request, originalURL: url, urlString: urlString, clientId: clientId,
                                 useAuth: useAuth, applyCookies: applyCookies, updateCookies: updateCookies,
                                 allowNewCookies: allowNewCookies, wantsBytes: wantsBytes, destination: authorized.destination)
            guard result["code"] as? Int == 429 else {
                clearRateLimit(for: host, ifGenerationIs: generation)
                return result
            }

            let delay = recordRateLimit(for: host, headers: result["headers"] as? [String: [String]] ?? [:])
            guard mayRetry, retryCount == 0, delay <= Self.maximumAutomaticRetryDelay,
                  now().addingTimeInterval(delay) < deadline else { return result }
            retryCount += 1
            sleep(delay)
        }
    }

    private func perform(
        _ request: URLRequest,
        originalURL url: URL,
        urlString: String,
        clientId: String,
        useAuth: Bool,
        applyCookies: Bool,
        updateCookies: Bool,
        allowNewCookies: Bool,
        wantsBytes: Bool,
        destination: CheckedDestination
    ) -> [String: Any] {

        let traceYouTubeAPI = ProcessInfo.processInfo.environment["HUMMINGBIRD_HTTP_TRACE"] == "1"
            && request.url?.host?.caseInsensitiveCompare("www.youtube.com") == .orderedSame
            && ["/youtubei/v1/player", "/youtubei/v1/next"].contains(request.url?.path)
        if traceYouTubeAPI {
            let headers = HTTPTrace.headers(request.allHTTPHeaderFields ?? [:])
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            PluginLog.httpTrace(LogRedaction.text(
                "youtube_api_request method=\(request.httpMethod ?? "") url=\(request.url?.absoluteString ?? urlString) headers=\(headers) body=\(body)",
                limit: HTTPTrace.limit
            ))
        }

        let traceUMP = ["1", "response"].contains(ProcessInfo.processInfo.environment["HUMMINGBIRD_UMP_TRACE"])
            && request.url?.host?.contains("googlevideo.com") == true
            && request.url?.query?.contains("sabr=1") == true
        let traceUMPRequest = ProcessInfo.processInfo.environment["HUMMINGBIRD_UMP_TRACE"] == "1"
        if traceUMPRequest && traceUMP {
            let headers = HTTPTrace.headers(request.allHTTPHeaderFields ?? [:])
            PluginLog.httpTrace(LogRedaction.text(
                "ump_request url=\(request.url?.absoluteString ?? urlString) headers=\(headers) bodyBytes=\(request.httpBody?.count ?? 0)",
                limit: HTTPTrace.limit
            ))
        }

        let taskGuard = TaskGuard(owner: self, clientId: clientId, applyCookies: applyCookies,
                                  updateCookies: updateCookies, allowNewCookies: allowNewCookies, useAuth: useAuth)
        let task = session.dataTask(with: request)
        task.delegate = taskGuard
        // Plugin HTTP blocks the plugin's worker, so slow upstream calls (and
        // throttled media fetched through a plugin) show up here by host.
        let signposter = OSSignposter.plugin
        let signpost = signposter.beginInterval("PluginHTTP", id: signposter.makeSignpostID(),
                                                "host=\(LogRedaction.redact(request.url?.host ?? ""), privacy: .public) method=\(request.httpMethod ?? "", privacy: .public)")
        task.resume()
        taskGuard.finished.wait()
        let outcome = taskGuard.outcome()
        let status = (outcome.response as? HTTPURLResponse)?.statusCode ?? -1
        signposter.endInterval("PluginHTTP", signpost, "status=\(status) bytes=\(outcome.data.count)")

        if let violation = outcome.violation {
            return ["error": violation, "errorType": "ScriptImplementationException"]
        }
        let responseData = outcome.data
        let response = outcome.response
        if let failure = outcome.failure {
            // A refused connection fails at the proxy; report why it refused.
            let failedURL = (failure as? URLError)?.failingURL ?? url
            if let proxy, let host = failedURL.host(percentEncoded: false) {
                let port = failedURL.port ?? (failedURL.scheme?.lowercased() == "https" ? 443 : 80)
                if let denial = proxy.denial(host: host, port: port) { return Self.denied(denial) }
            }
            if (failure as? URLError)?.code == .timedOut {
                // Timeouts come back as a 408 response rather than an exception.
                return ["code": 408, "url": "", "body": NSNull(), "headers": [String: [String]]()]
            }
            return ["error": failure.localizedDescription]
        }
        guard let http = response as? HTTPURLResponse else { return ["error": "No HTTP response"] }

        if traceYouTubeAPI {
            let responseHeaders = HTTPTrace.headers(http.allHeaderFields)
            let body = String(decoding: responseData, as: UTF8.self)
            PluginLog.httpTrace(LogRedaction.text(
                "youtube_api_response url=\(http.url?.absoluteString ?? urlString) status=\(http.statusCode) headers=\(responseHeaders) body=\(body)",
                limit: HTTPTrace.limit
            ))
        }

        if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1",
           !(200..<300).contains(http.statusCode) {
            let body = String(decoding: responseData.prefix(2_048), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "\\n")
            PluginLog.httpFailure(LogRedaction.text(
                "plugin_http_failure method=\(request.httpMethod ?? "") status=\(http.statusCode) url=\(http.url?.absoluteString ?? urlString) body=\(body)",
                limit: HTTPTrace.limit
            ))
        }

        if traceUMP {
            let responseHeaders = HTTPTrace.headers(http.allHeaderFields)
            let prefix = responseData.prefix(512).base64EncodedString()
            PluginLog.httpTrace(LogRedaction.text(
                "ump_response status=\(http.statusCode) bodyBytes=\(responseData.count) url=\(http.url?.absoluteString ?? urlString) headers=\(responseHeaders) bodyPrefixBase64=\(prefix)",
                limit: HTTPTrace.limit
            ))
        }

        var rawHeaders: [String: String] = [:]
        var headerMap: [String: [String]] = [:]
        for (k, v) in http.allHeaderFields {
            guard let key = k as? String else { continue }
            rawHeaders[key] = "\(v)"
            headerMap[key.lowercased(), default: []].append("\(v)")
        }
        if updateCookies {
            ingestCookies(headers: rawHeaders, url: http.url ?? url, clientId: clientId, useAuth: useAuth, allowNew: allowNewCookies)
        }
        let loggedIn = useAuth && auth != nil
        if !(config.allowAllHttpHeaderAccess || loggedIn) {
            headerMap = headerMap.filter { Self.visibleHeaders.contains($0.key) }
        }

        var out: [String: Any] = [
            "url": http.url?.absoluteString ?? urlString,
            "code": http.statusCode,
            "headers": headerMap,
        ]
        if wantsBytes { out["bodyBase64"] = responseData.base64EncodedString() }
        else { out["body"] = String(data: responseData, encoding: .utf8) ?? String(decoding: responseData, as: UTF8.self) }
        return out
    }

    // MARK: rate limiting

    private func rateLimitRemaining(for host: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let state = rateLimits[host] else { return nil }
        let remaining = state.until.timeIntervalSince(now())
        if remaining <= 0 { return nil }
        return remaining
    }

    /// Starts or extends a host's cooldown. Internal so tests can record a
    /// concurrent 429 while a request is in flight.
    @discardableResult
    func recordRateLimit(for host: String, headers: [String: [String]]) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let failures = (rateLimits[host]?.failures ?? 0) + 1
        let fallback = min(pow(2, Double(failures - 1)), 60)
        let delay = Self.retryDelay(from: headers["retry-after"]?.first, now: now()) ?? fallback
        rateLimitGenerations[host, default: 0] &+= 1
        rateLimits[host] = (now().addingTimeInterval(delay), failures)
        return delay
    }

    private func rateLimitGeneration(for host: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return rateLimitGenerations[host, default: 0]
    }

    private func clearRateLimit(for host: String, ifGenerationIs generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard rateLimitGenerations[host, default: 0] == generation else { return }
        rateLimits.removeValue(forKey: host)
    }

    private func rateLimitedResponse(url: String, retryAfter: TimeInterval, wantsBytes: Bool) -> [String: Any] {
        let rounded = retryAfter.isFinite ? min(max(1, ceil(retryAfter)), Self.maximumRetryAfter) : 1
        let seconds = Int(rounded)
        var response: [String: Any] = [
            "url": url,
            "code": 429,
            "headers": ["retry-after": [String(seconds)]],
        ]
        if wantsBytes { response["bodyBase64"] = Data("Too Many Requests".utf8).base64EncodedString() }
        else { response["body"] = "Too Many Requests" }
        return response
    }

    static func retryDelay(from value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
           let seconds = TimeInterval(trimmed), seconds.isFinite,
           seconds >= 0, seconds <= maximumRetryAfter {
            return seconds
        }
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let delay = max(0, date.timeIntervalSince(now))
                guard delay.isFinite, delay <= maximumRetryAfter else { return nil }
                return delay
            }
        }
        return nil
    }

    // MARK: client controls

    /// Clients a plugin may create (each holds a cookie jar).
    static let maximumClients = 64

    private func handleControl(_ control: String, _ req: [String: Any]) {
        let id = req["clientId"] as? String ?? ""
        lock.lock(); defer { lock.unlock() }
        switch control {
        case "newClient":
            guard clients.count < Self.maximumClients || clients[id] != nil else { return }
            clients[id] = makeState(withAuth: req["withAuth"] as? Bool ?? false)
        case "resetAuthCookies":
            if let st = clients[id] { clients[id] = ClientState(withAuth: st.withAuth, currentCookies: makeState(withAuth: st.withAuth).currentCookies, otherCookies: st.otherCookies) }
        case "clearOtherCookies":
            clients[id]?.otherCookies = [:]
        default: break
        }
    }

    // MARK: cookies

    fileprivate func cookieHeader(clientId: String, host: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let st = clients[clientId] else { return "" }
        var pairs: [String: String] = [:]
        for map in [st.otherCookies, st.currentCookies] {
            for (domain, cookies) in map where domainMatches(host: host, domain: domain) {
                for (name, value) in cookies { pairs[name] = value }
            }
        }
        return pairs.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    /// Cookies per client jar, so a hostile server cannot grow one without bound.
    static let maximumCookiesPerClient = 512

    fileprivate func ingestCookies(headers: [String: String], url: URL, clientId: String, useAuth: Bool, allowNew: Bool) {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !cookies.isEmpty, let host = url.host?.lowercased() else { return }
        lock.lock(); defer { lock.unlock() }
        guard var st = clients[clientId] else { return }
        let loggedIn = useAuth && auth != nil
        for c in cookies {
            var domain = c.domain.lowercased()
            if !domain.hasPrefix(".") {
                let labels = host.split(separator: ".")
                let base = labels.count >= 2 ? labels.suffix(2).joined(separator: ".") : host
                domain = "." + base
            }
            let isDeletion = c.value.isEmpty || (c.expiresDate.map { $0 <= now() } ?? false)
            let total = st.currentCookies.values.reduce(0) { $0 + $1.count } + st.otherCookies.values.reduce(0) { $0 + $1.count }
            let roomForNew = total < Self.maximumCookiesPerClient
            if loggedIn || !st.currentCookies.isEmpty {
                if isDeletion {
                    st.currentCookies[domain]?.removeValue(forKey: c.name)
                } else if (allowNew && roomForNew) || st.currentCookies[domain]?[c.name] != nil {
                    st.currentCookies[domain, default: [:]][c.name] = c.value
                }
            } else {
                if isDeletion {
                    st.otherCookies[domain]?.removeValue(forKey: c.name)
                } else if (allowNew && roomForNew) || st.otherCookies[domain]?[c.name] != nil {
                    st.otherCookies[domain, default: [:]][c.name] = c.value
                }
            }
        }
        clients[clientId] = st
    }
}

/// Per-request delegate: every redirect hop must pass the plugin's policy, cookies are re-evaluated per host,
/// the body is capped, and no credential the plugin did not supply is ever offered (HTTP auth, client
/// certificates, proxy credentials).
private final class TaskGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let owner: HostHTTP
    let clientId: String
    let applyCookies: Bool
    let updateCookies: Bool
    let allowNewCookies: Bool
    let useAuth: Bool
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var failure: Error?
    private var violation: String?

    init(owner: HostHTTP, clientId: String, applyCookies: Bool, updateCookies: Bool, allowNewCookies: Bool, useAuth: Bool) {
        self.owner = owner; self.clientId = clientId; self.applyCookies = applyCookies
        self.updateCookies = updateCookies; self.allowNewCookies = allowNewCookies; self.useAuth = useAuth
    }

    func outcome() -> (data: Data, response: URLResponse?, failure: Error?, violation: String?) {
        lock.withLock { (data, response, failure, violation) }
    }

    private func fail(_ message: String) { lock.withLock { if violation == nil { violation = message } } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if response.expectedContentLength > Int64(PluginLimits.maximumResponseBodyBytes) {
            fail("The response is larger than plugins may receive (\(PluginLimits.maximumResponseBodyBytes / 1_048_576) MB)")
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over: Bool = lock.withLock {
            data.append(chunk)
            return data.count > PluginLimits.maximumResponseBodyBytes
        }
        if over {
            fail("The response is larger than plugins may receive (\(PluginLimits.maximumResponseBodyBytes / 1_048_576) MB)")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            failure = error
            if response == nil { response = task.response }
        }
        finished.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Server trust is evaluated by the system as usual; nothing else is answered.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.rejectProtectionSpace, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if updateCookies, let from = response.url {
            var raw: [String: String] = [:]
            for (k, v) in response.allHeaderFields { if let ks = k as? String { raw[ks] = "\(v)" } }
            owner.ingestCookies(headers: raw, url: from, clientId: clientId, useAuth: useAuth, allowNew: allowNewCookies)
        }
        guard let url = request.url else { completionHandler(nil); return }
        // Behind the egress proxy the resolved address is checked when the hop connects, so this
        // callback stays free of DNS (it would stall the session's other callbacks); without the
        // proxy, the full check runs here.
        let hopHost: String
        if owner.proxy != nil {
            switch owner.policy.precheck(url: url) {
            case .success: hopHost = PluginNetworkPolicy.normalizedHost(url.host(percentEncoded: false) ?? "")
            case .failure(let denial):
                fail("\(denial.localizedDescription) (redirect)")
                completionHandler(nil)
                return
            }
        } else {
            switch owner.mayReach(url) {
            case .success(let request): hopHost = request.destination.host
            case .failure(let denial):
                fail("\(denial.localizedDescription) (redirect)")
                completionHandler(nil)
                return
            }
        }
        var next = request
        if applyCookies {
            let cookie = owner.cookieHeader(clientId: clientId, host: hopHost)
            next.setValue(cookie.isEmpty ? nil : cookie, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }
}

/// Formats headers for the opt-in HTTP traces (`HUMMINGBIRD_HTTP_TRACE`,
/// `HUMMINGBIRD_UMP_TRACE`). Traces are logged as private data, and
/// credential-bearing header values are dropped even from that.
enum HTTPTrace {
    /// Traces are opt-in diagnostics of whole requests, so they keep more
    /// than an ordinary log line, still redacted.
    static let limit = 8_000

    static func headers(_ fields: [String: String]) -> String {
        fields.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \(isCredential($0.key) ? "<redacted>" : $0.value)" }
            .joined(separator: "\\n")
    }

    static func headers(_ fields: [AnyHashable: Any]) -> String {
        var strings: [String: String] = [:]
        for (key, value) in fields { strings["\(key)"] = "\(value)" }
        return headers(strings)
    }

    static func isCredential(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["authorization", "cookie", "token", "auth", "key", "secret", "session", "dpop", "visitor", "identity"]
            .contains { name.contains($0) }
    }
}
