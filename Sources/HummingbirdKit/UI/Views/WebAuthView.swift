#if canImport(WebKit)
import Foundation
import Observation
import SwiftOpenUI
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
        // GTK's presented-window host does not currently deliver SwiftUI task
        // or appearance callbacks reliably. Starting here is idempotent and
        // ensures completion/cookie polling is active as soon as the sheet is
        // rendered. Completion and cancellation both stop the task.
        let _ = session.start()
        NavigationStack {
            VStack(spacing: 0) {
                WebView(session.page)
                // A web view has no intrinsic content size. Give presented
                // windows an initial proposal while still allowing them to
                // fill whatever space the platform provides.
                .frame(
                    minWidth: 320, maxWidth: .infinity,
                    minHeight: 320, maxHeight: .infinity
                )
                .ignoresSafeArea(edges: .bottom)
                if session.credentialsReady {
                    HStack {
                        Text("Credentials ready").font(.headline)
                        Spacer()
                        Button("Done") { Task { await session.finish() } }
                    }
                    .padding()
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.85))
                }
            }
                .navigationTitle(spec.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.cancel() } }
                    if !spec.hasExplicitCompletion {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { Task { await session.finish() } }
                        }
                    }
                }
                .onDisappear { session.stop() }
        }
    }
}

@MainActor
@Observable
final class WebAuthSession {
    let page: WebPage
    private(set) var credentialsReady = false
    private let dataStore: WKWebsiteDataStore
    private let spec: WebAuthSpec
    private let onFinish: (SourceAuth?) -> Void
    private var headers: [String: [String: String]] = [:]
    private var cookies: [String: [String: String]] = [:]
    private var completionSeen: Bool
    private var userAgent: String?
    private var finished = false
    private var clickedLoginButton = false
    private var pollingTask: Task<Void, Never>?

    init(spec: WebAuthSpec, onFinish: @escaping (SourceAuth?) -> Void) {
        self.spec = spec
        self.onFinish = onFinish
        completionSeen = spec.completionURL == nil
        dataStore = .nonPersistent()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.captureScript.replacingOccurrences(of: "__CAPTURE_CHANNEL__", with: UUID().uuidString),
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        page = WebPage(configuration: configuration)
        page.customUserAgent = spec.userAgent
        if let html = spec.html {
            page.load(html: html, baseURL: spec.startURL ?? URL(string: "about:blank")!)
        } else {
            page.load(spec.startURL)
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.pollOnce() == true else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollOnce() async -> Bool {
        guard !finished else { return false }
        await inspectPage()
        return !finished
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        page.stopLoading()
        pollingTask?.cancel()
        onFinish(nil)
    }

    func finish() async {
        guard !finished else { return }
        await inspectPage()
        guard !finished else { return }
        finished = true
        page.stopLoading()
        pollingTask?.cancel()
        onFinish(SourceAuth(cookieMap: cookies, headers: headers, userAgent: userAgent ?? spec.userAgent))
    }

    private func inspectPage() async {
        guard let url = page.url else { return }
        checkCompletion(url)
        if let snapshot = try? await page.callJavaScript(Self.snapshotScript) as? String,
           let data = snapshot.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            userAgent = object["userAgent"] as? String ?? userAgent
            for item in object["requests"] as? [[String: Any]] ?? [] {
                guard item["completed"] as? Bool == true,
                      let rawURL = item["url"] as? String, let url = URL(string: rawURL) else { continue }
                var requestHeaders: [String: String] = [:]
                for (name, value) in item["headers"] as? [String: Any] ?? [:] {
                    requestHeaders[name] = String(describing: value)
                }
                recordHeaders(requestHeaders, url: url)
                // Some plugins complete at a fetch/XHR API endpoint. Required
                // headers must come from this successful request, not an
                // earlier failed or unrelated request.
                if spec.hasCompletionHeaders(requestHeaders, url: url) { checkCompletion(url) }
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
        if satisfied() { credentialsReady = true }
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
        if !completionSeen, spec.matchesCompletion(url) { completionSeen = true }
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
      const channel = '__CAPTURE_CHANNEL__';
      // Each frame has a separate JS global. Forward cross-origin iframe
      // events to the top frame, whose queue is drained by the native poller.
      if (window === window.top) window.addEventListener('message', event => {
        if (event.data && event.data.channel === channel && event.data.request)
          window.__hummingbirdAuthCapture.push(event.data.request);
      });
      const record = (url, headers) => {
        try {
          const request = {url, headers, completed: true};
          if (window === window.top) window.__hummingbirdAuthCapture.push(request);
          else window.top.postMessage({channel, request}, '*');
        } catch (_) {}
      };
      const originalFetch = window.fetch;
      if (originalFetch) window.fetch = function(input, init) {
        let url;
        const headers = {};
        try {
          url = String(new URL(input && input.url !== undefined ? input.url : String(input), document.baseURI));
          const source = (init && init.headers) || (input && input.headers);
          if (source && typeof source.forEach === 'function') source.forEach((value, name) => headers[name] = value);
          else if (Array.isArray(source)) source.forEach(pair => headers[pair[0]] = pair[1]);
          else if (source) Object.keys(source).forEach(name => headers[name] = source[name]);
        } catch (_) {}
        return originalFetch.apply(this, arguments).then(response => {
          if (response.ok && url) record(url, headers);
          return response;
        });
      };
      const open = XMLHttpRequest.prototype.open;
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__hb = {url: String(new URL(url, document.baseURI)), headers: {}};
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) { if (this.__hb) this.__hb.headers[name] = value; return setHeader.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function() {
        const request = this.__hb;
        if (request) {
          this.addEventListener('loadend', () => {
            if (this.status >= 200 && this.status < 300) record(request.url, request.headers);
          }, {once: true});
        }
        return send.apply(this, arguments);
      };
    })();
    """#

    private static let snapshotScript = #"""
    const requests = window.__hummingbirdAuthCapture || [];
    window.__hummingbirdAuthCapture = [];
    return JSON.stringify({requests, userAgent: navigator.userAgent});
    """#
}
#endif

// MARK: - QR scanner

#if os(iOS)
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

#elseif os(macOS)
import AppKit
import AVFoundation

struct QRScannerView: NSViewRepresentable {
    let onCode: (String) -> Void

    func makeNSView(context: Context) -> ScannerNSView {
        let v = ScannerNSView()
        v.onCode = onCode
        return v
    }
    func updateNSView(_ nsView: ScannerNSView, context: Context) {}

    final class ScannerNSView: NSView, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
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
            self.layer?.addSublayer(layer)
            preview = layer
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            preview?.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    if !session.isRunning { session.startRunning() }
                }
            } else {
                session.stopRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(code)
        }
    }
}
#endif
