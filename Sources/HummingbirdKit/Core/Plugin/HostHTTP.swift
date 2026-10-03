import Foundation

/// Native side of the plugin `http` package. The JS wrapper (prelude.js) batches requests and calls `execute`
/// with a JSON array; this class performs them (optionally in parallel), enforcing the plugin's allow-list,
/// applying stored credentials and cookies, and returning a JSON array of response objects.
final class HostHTTP: NSObject {
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
        "content-encoding", "content-disposition", "connection",
    ]

    let config: PluginConfig
    private let auth: SourceAuth?
    private let captcha: SourceAuth?
    private var clients: [String: ClientState] = [:]
    private let lock = NSLock()
    private let session: URLSession

    init(config: PluginConfig, auth: SourceAuth?, captcha: SourceAuth?) {
        self.config = config
        self.auth = auth
        self.captcha = captcha
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        super.init()
        clients["default-anon"] = makeState(withAuth: false)
        clients["default-auth"] = makeState(withAuth: true)
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

    // MARK: entry point

    func execute(json: String, parallel: Bool) -> String {
        guard let data = json.data(using: .utf8),
              let requests = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return "[]" }
        var results = [[String: Any]](repeating: [:], count: requests.count)
        let resultLock = NSLock()
        let runOne: (Int) -> Void = { [self] i in
            let r = run(requests[i])
            resultLock.lock(); results[i] = r; resultLock.unlock()
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
        let out = (try? JSONSerialization.data(withJSONObject: results)) ?? Data("[]".utf8)
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: one request

    private func run(_ req: [String: Any]) -> [String: Any] {
        if let control = req["control"] as? String {
            handleControl(control, req)
            return ["code": 200]
        }
        guard let method = req["method"] as? String,
              let urlString = req["url"] as? String,
              let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return ["error": "Invalid request URL"] }

        guard config.allowsHost(host) else {
            return ["error": "Attempted to access non-whitelisted url: \(urlString). Add the host to allowUrls in the plugin config.",
                    "errorType": "ScriptImplementationException"]
        }

        let clientId = req["clientId"] as? String ?? "default-anon"
        let useAuth = req["useAuth"] as? Bool ?? false
        let applyCookies = req["applyCookies"] as? Bool ?? true
        let updateCookies = req["updateCookies"] as? Bool ?? true
        let allowNewCookies = req["allowNewCookies"] as? Bool ?? true
        let wantsBytes = req["bytes"] as? Bool ?? false

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let ms = req["timeoutMs"] as? Double, ms > 0 { request.timeoutInterval = ms / 1000 }

        var headers: [String: String] = [:]
        if let h = req["headers"] as? [String: Any] { for (k, v) in h { headers[k] = "\(v)" } }
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
            if let text = body["text"] as? String { request.httpBody = Data(text.utf8) }
            else if let b64 = body["b64"] as? String { request.httpBody = Data(base64Encoded: b64) }
        }

        let redirectGuard = RedirectGuard(owner: self, clientId: clientId, applyCookies: applyCookies,
                                          updateCookies: updateCookies, allowNewCookies: allowNewCookies, useAuth: useAuth)
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: URLResponse?
        var failure: Error?
        let task = session.dataTask(with: request) { d, r, e in
            responseData = d; response = r; failure = e
            semaphore.signal()
        }
        task.delegate = redirectGuard
        task.resume()
        semaphore.wait()
        withExtendedLifetime(redirectGuard) {}

        if let violation = redirectGuard.violation {
            return ["error": violation, "errorType": "ScriptImplementationException"]
        }
        if let failure {
            if (failure as? URLError)?.code == .timedOut {
                // Timeouts come back as a 408 response rather than an exception.
                return ["code": 408, "url": "", "body": NSNull(), "headers": [String: [String]]()]
            }
            return ["error": failure.localizedDescription]
        }
        guard let http = response as? HTTPURLResponse else { return ["error": "No HTTP response"] }

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
        let bytes = responseData ?? Data()
        if wantsBytes { out["bodyBase64"] = bytes.base64EncodedString() }
        else { out["body"] = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self) }
        return out
    }

    // MARK: client controls

    private func handleControl(_ control: String, _ req: [String: Any]) {
        let id = req["clientId"] as? String ?? ""
        lock.lock(); defer { lock.unlock() }
        switch control {
        case "newClient":
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
            if loggedIn || !st.currentCookies.isEmpty {
                if allowNew || st.currentCookies[domain]?[c.name] != nil { st.currentCookies[domain, default: [:]][c.name] = c.value }
            } else {
                if allowNew || st.otherCookies[domain]?[c.name] != nil { st.otherCookies[domain, default: [:]][c.name] = c.value }
            }
        }
        clients[clientId] = st
    }
}

/// Per-request redirect policy: every hop must pass the plugin's allow-list, and cookies are re-evaluated per host.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let owner: HostHTTP
    let clientId: String
    let applyCookies: Bool
    let updateCookies: Bool
    let allowNewCookies: Bool
    let useAuth: Bool
    var violation: String?

    init(owner: HostHTTP, clientId: String, applyCookies: Bool, updateCookies: Bool, allowNewCookies: Bool, useAuth: Bool) {
        self.owner = owner; self.clientId = clientId; self.applyCookies = applyCookies
        self.updateCookies = updateCookies; self.allowNewCookies = allowNewCookies; self.useAuth = useAuth
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if updateCookies, let from = response.url {
            var raw: [String: String] = [:]
            for (k, v) in response.allHeaderFields { if let ks = k as? String { raw[ks] = "\(v)" } }
            owner.ingestCookies(headers: raw, url: from, clientId: clientId, useAuth: useAuth, allowNew: allowNewCookies)
        }
        guard let host = request.url?.host?.lowercased() else { completionHandler(nil); return }
        guard owner.config.allowsHost(host) else {
            violation = "Attempted to access non-whitelisted url: \(request.url?.absoluteString ?? host) (redirect)"
            completionHandler(nil)
            return
        }
        var next = request
        if applyCookies {
            let cookie = owner.cookieHeader(clientId: clientId, host: host)
            next.setValue(cookie.isEmpty ? nil : cookie, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }
}
