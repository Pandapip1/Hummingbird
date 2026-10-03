import Foundation
#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit
import AVFoundation

@MainActor
struct WebAuthSheet: View {
    let spec: WebAuthSpec
    let onFinish: (SourceAuth?) -> Void
    @State private var coordinatorBox = CoordinatorBox()

    var body: some View {
        NavigationStack {
            WebAuthView(spec: spec, box: coordinatorBox, onFinish: onFinish)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(spec.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinish(nil) } }
                    if !spec.hasExplicitCompletion {
                        // Without completion rules we cannot tell when sign-in is done, so let the person say so.
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { coordinatorBox.coordinator?.finishNow() } }
                    }
                }
        }
    }
}

final class CoordinatorBox { weak var coordinator: WebAuthView.Coordinator? }

struct WebAuthView: UIViewRepresentable {
    let spec: WebAuthSpec
    let box: CoordinatorBox
    let onFinish: (SourceAuth?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(spec: spec, onFinish: onFinish) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "jbHeaders")
        controller.addUserScript(WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = controller
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if let ua = spec.userAgent { web.customUserAgent = ua }
        context.coordinator.webView = web
        box.coordinator = context.coordinator
        if let html = spec.html { web.loadHTMLString(html, baseURL: spec.startURL) }
        else if let url = spec.startURL { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "jbHeaders")
    }

    // Records the headers of requests the page makes with fetch / XMLHttpRequest. Navigations are covered by the
    // navigation delegate. Page scripts only; requests made by the browser engine itself cannot be observed.
    static let hookScript = """
    (function () {
      if (window.__jbHooked) return; window.__jbHooked = true;
      function post(url, headers) {
        try { window.webkit.messageHandlers.jbHeaders.postMessage({ url: String(url), headers: headers || {} }); } catch (e) {}
      }
      function abs(u) { try { return new URL(u, location.href).href; } catch (e) { return String(u); } }
      var of = window.fetch;
      if (of) window.fetch = function (input, init) {
        try {
          var h = {};
          var src = (init && init.headers) || (input && input.headers);
          if (src) {
            if (typeof src.forEach === 'function' && !Array.isArray(src)) src.forEach(function (v, k) { h[k] = v; });
            else if (Array.isArray(src)) src.forEach(function (p) { h[p[0]] = p[1]; });
            else Object.keys(src).forEach(function (k) { h[k] = src[k]; });
          }
          post(abs(typeof input === 'string' ? input : input.url), h);
        } catch (e) {}
        return of.apply(this, arguments);
      };
      var xo = XMLHttpRequest.prototype.open, xs = XMLHttpRequest.prototype.setRequestHeader, xd = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__jb = { url: u, headers: {} }; return xo.apply(this, arguments); };
      XMLHttpRequest.prototype.setRequestHeader = function (k, v) { if (this.__jb) this.__jb.headers[k] = v; return xs.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () { try { if (this.__jb) post(abs(this.__jb.url), this.__jb.headers); } catch (e) {} return xd.apply(this, arguments); };
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let spec: WebAuthSpec
        let onFinish: (SourceAuth?) -> Void
        weak var webView: WKWebView?
        private var headers: [String: [String: String]] = [:]
        private var cookies: [String: [String: String]] = [:]
        private var completionSeen: Bool
        private var userAgent: String?
        private var finished = false
        private var clickedLoginButton = false

        init(spec: WebAuthSpec, onFinish: @escaping (SourceAuth?) -> Void) {
            self.spec = spec
            self.onFinish = onFinish
            self.completionSeen = spec.completionURL == nil
        }

        // MARK: header capture

        private func recordHeaders(_ requestHeaders: [String: String], url: URL) {
            guard let host = url.host?.lowercased() else { return }
            if let allowed = spec.allowedDomains, !allowed.isEmpty, !allowed.contains(where: { $0.lowercased() == host }) { return }
            for (rawName, value) in requestHeaders {
                let name = rawName.lowercased()
                if name == "authorization", value == "undefined" { continue }
                if spec.headersToFind.contains(where: { $0.lowercased() == name }) { headers[host, default: [:]][name] = value }
                for (domain, names) in spec.domainHeadersToFind where domainMatches(host: host, domain: domain) {
                    if names.contains(where: { $0.lowercased() == name }) { headers[domain, default: [:]][name] = value }
                }
            }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let urlString = body["url"] as? String, let url = URL(string: urlString) else { return }
            var h: [String: String] = [:]
            for (k, v) in (body["headers"] as? [String: Any] ?? [:]) { h[k] = "\(v)" }
            recordHeaders(h, url: url)
            readCookiesThenEvaluate()
        }

        // MARK: navigation

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url {
                recordHeaders(action.request.allHTTPHeaderFields ?? [:], url: url)
                checkCompletion(url)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { checkCompletion(url) }
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in self?.userAgent = result as? String }
            if !clickedLoginButton, let sel = spec.loginButtonSelector,
               sel.range(of: "^[a-zA-Z\\-\\.#:_ ]*$", options: .regularExpression) != nil {
                clickedLoginButton = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    webView.evaluateJavaScript("var e=document.querySelector(\(jsString(sel))); if(e) e.click();")
                }
            }
            readCookiesThenEvaluate()
        }

        // MARK: completion

        private func checkCompletion(_ url: URL) {
            guard let target = spec.completionURL, !completionSeen else { return }
            if target.hasSuffix("?*") {
                let base = String(target.dropLast(2))
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                c?.query = nil; c?.fragment = nil
                if c?.string == base || url.absoluteString.hasPrefix(base) { completionSeen = true }
            } else if url.absoluteString == target { completionSeen = true }
        }

        private func readCookiesThenEvaluate() {
            guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { evaluate(); return }
            store.getAllCookies { [weak self] all in
                guard let self else { return }
                for c in all {
                    let host = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    guard self.spec.hostAllowed(host.lowercased()) else { continue }
                    if self.spec.cookiesExclOthers && !self.spec.cookiesToFind.contains(c.name) { continue }
                    let key = c.domain.hasPrefix(".") ? c.domain : "." + c.domain
                    self.cookies[key.lowercased(), default: [:]][c.name] = c.value
                }
                self.evaluate()
            }
        }

        private func satisfied() -> Bool {
            guard completionSeen else { return false }
            if !spec.hasExplicitCompletion { return false }
            let foundHeaderNames = Set(headers.values.flatMap { $0.keys })
            for n in spec.headersToFind where !foundHeaderNames.contains(n.lowercased()) { return false }
            for (domain, names) in spec.domainHeadersToFind {
                let have = headers[domain] ?? [:]
                for n in names where have[n.lowercased()] == nil { return false }
            }
            let foundCookieNames = Set(cookies.values.flatMap { $0.keys })
            for n in spec.cookiesToFind where !foundCookieNames.contains(n) { return false }
            return true
        }

        private func evaluate() {
            guard !finished, satisfied() else { return }
            finishNow()
        }

        func finishNow() {
            guard !finished else { return }
            finished = true
            onFinish(SourceAuth(cookieMap: cookies, headers: headers, userAgent: userAgent))
        }
    }
}

// MARK: - QR scanner

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
