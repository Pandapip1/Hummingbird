import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif
import WebKit

@MainActor
struct WebAuthSheet: View {
    let spec: WebAuthSpec
    let onFinish: (SourceAuth?) -> Void
    @State private var session: WebAuthSession

    init(spec: WebAuthSpec, onFinish: @escaping (SourceAuth?) -> Void) {
        self.spec = spec
        self.onFinish = onFinish
        _session = State(wrappedValue: WebAuthSession(spec: spec, onFinish: onFinish))
    }

    var body: some View {
        NavigationStack {
            WebView(session.page)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(spec.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.cancel() } }
                    if !spec.hasExplicitCompletion {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { session.finish() } }
                    }
                }
                .task { await session.run() }
        }
    }
}

@MainActor
private final class WebAuthSession {
    let page: WebPage
    private let dataStore: WKWebsiteDataStore
    private let spec: WebAuthSpec
    private let onFinish: (SourceAuth?) -> Void
    private var headers: [String: [String: String]] = [:]
    private var cookies: [String: [String: String]] = [:]
    private var completionSeen: Bool
    private var userAgent: String?
    private var finished = false
    private var clickedLoginButton = false

    init(spec: WebAuthSpec, onFinish: @escaping (SourceAuth?) -> Void) {
        self.spec = spec
        self.onFinish = onFinish
        completionSeen = spec.completionURL == nil
        dataStore = .nonPersistent()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        page = WebPage(configuration: configuration)
        page.customUserAgent = spec.userAgent
    }

    func run() async {
        if let html = spec.html {
            page.load(html: html, baseURL: spec.startURL ?? URL(string: "about:blank")!)
        } else {
            page.load(spec.startURL)
        }
        while !Task.isCancelled, !finished {
            await inspectPage()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        page.stopLoading()
        onFinish(nil)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        page.stopLoading()
        onFinish(SourceAuth(cookieMap: cookies, headers: headers, userAgent: userAgent ?? spec.userAgent))
    }

    private func inspectPage() async {
        if let url = page.url { checkCompletion(url) }
        if let snapshot = try? await page.callJavaScript(Self.snapshotScript) as? String,
           let data = snapshot.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            userAgent = object["userAgent"] as? String ?? userAgent
            for item in object["requests"] as? [[String: Any]] ?? [] {
                guard let rawURL = item["url"] as? String, let url = URL(string: rawURL) else { continue }
                var requestHeaders: [String: String] = [:]
                for (name, value) in item["headers"] as? [String: Any] ?? [:] {
                    requestHeaders[name] = String(describing: value)
                }
                recordHeaders(requestHeaders, url: url)
            }
        }

        if !clickedLoginButton, page.url != nil, let selector = spec.loginButtonSelector,
           selector.range(of: "^[a-zA-Z\\-\\.#:_ ]*$", options: .regularExpression) != nil {
            clickedLoginButton = true
            _ = try? await page.callJavaScript(
                "const element = document.querySelector(selector); if (element) { element.click(); }",
                arguments: ["selector": selector]
            )
        }

        for cookie in await dataStore.httpCookieStore.allCookies() {
            let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard spec.hostAllowed(host.lowercased()) else { continue }
            if spec.cookiesExclOthers && !spec.cookiesToFind.contains(cookie.name) { continue }
            let domain = cookie.domain.hasPrefix(".") ? cookie.domain : "." + cookie.domain
            cookies[domain.lowercased(), default: [:]][cookie.name] = cookie.value
        }
        if satisfied() { finish() }
    }

    private func recordHeaders(_ requestHeaders: [String: String], url: URL) {
        guard let host = url.host?.lowercased() else { return }
        if let allowed = spec.allowedDomains, !allowed.isEmpty,
           !allowed.contains(where: { domainMatches(host: host, domain: $0.lowercased()) }) { return }
        for (rawName, value) in requestHeaders {
            let name = rawName.lowercased()
            if name == "authorization", value == "undefined" { continue }
            if spec.headersToFind.contains(where: { $0.lowercased() == name }) {
                headers[host, default: [:]][name] = value
            }
            for (domain, names) in spec.domainHeadersToFind where domainMatches(host: host, domain: domain) {
                if names.contains(where: { $0.lowercased() == name }) {
                    headers[domain, default: [:]][name] = value
                }
            }
        }
    }

    private func checkCompletion(_ url: URL) {
        guard let target = spec.completionURL, !completionSeen else { return }
        if target.hasSuffix("?*") {
            let base = String(target.dropLast(2))
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            if components?.string == base || url.absoluteString.hasPrefix(base) { completionSeen = true }
        } else if url.absoluteString == target {
            completionSeen = true
        }
    }

    private func satisfied() -> Bool {
        guard completionSeen, spec.hasExplicitCompletion else { return false }
        let foundHeaderNames = Set(headers.values.flatMap(\.keys))
        for name in spec.headersToFind where !foundHeaderNames.contains(name.lowercased()) { return false }
        for (domain, names) in spec.domainHeadersToFind {
            let found = headers[domain] ?? [:]
            for name in names where found[name.lowercased()] == nil { return false }
        }
        let foundCookieNames = Set(cookies.values.flatMap(\.keys))
        for name in spec.cookiesToFind where !foundCookieNames.contains(name) { return false }
        return true
    }

    private static let captureScript = #"""
    (() => {
      if (window.__hummingbirdAuthCapture) return;
      window.__hummingbirdAuthCapture = [];
      const record = (url, headers) => {
        try { window.__hummingbirdAuthCapture.push({url: String(new URL(url, location.href)), headers: headers || {}}); } catch (_) {}
      };
      const originalFetch = window.fetch;
      if (originalFetch) window.fetch = function(input, init) {
        try {
          const headers = {};
          const source = (init && init.headers) || (input && input.headers);
          if (source && typeof source.forEach === 'function') source.forEach((value, name) => headers[name] = value);
          else if (Array.isArray(source)) source.forEach(pair => headers[pair[0]] = pair[1]);
          else if (source) Object.keys(source).forEach(name => headers[name] = source[name]);
          record(typeof input === 'string' ? input : input.url, headers);
        } catch (_) {}
        return originalFetch.apply(this, arguments);
      };
      const open = XMLHttpRequest.prototype.open;
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) { this.__hb = {url, headers: {}}; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) { if (this.__hb) this.__hb.headers[name] = value; return setHeader.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function() { if (this.__hb) record(this.__hb.url, this.__hb.headers); return send.apply(this, arguments); };
    })();
    """#

    private static let snapshotScript = #"""
    const requests = window.__hummingbirdAuthCapture || [];
    window.__hummingbirdAuthCapture = [];
    return JSON.stringify({requests, userAgent: navigator.userAgent});
    """#
}

// MARK: - QR scanner

#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in if !session.isRunning { session.startRunning() } }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(code)
        }
    }
}
#endif
