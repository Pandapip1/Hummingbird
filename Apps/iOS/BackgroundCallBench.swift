#if DEBUG && os(iOS)
import AVFoundation
import Foundation
import JavaScriptCore
import UIKit
import WebKit

/// Measurement only, in Debug builds, and only when launched with HUMMINGBIRD_BACKGROUND_BENCH=1
/// (scripts/measure-background-calls): whether plugin calls still complete while the app is in
/// the background playing audio (UIBackgroundModes=audio), per way of hosting them:
///   (a) a fresh JSContext per call, off the main thread (today's runtime),
///   (b) a fresh WKContentWorld per call in one hidden page (the WebKit arrangement),
///   (c) a hidden page on youtube.com, as the YouTube plugin's browser package keeps for
///       BotGuard/PoToken: a script round trip and a same-origin fetch from the page (needs DNS
///       and network: valid only if it succeeds in the foreground phase),
///   (d) the same on a local page (a custom scheme the app answers, no network), so WebKit
///       throttling can be told apart from network failures.
/// Pages (c) and (d) run a 250 ms timer; each result carries the largest gap between its ticks
/// since the previous call (`timer_max_gap_ms`): a suspended WebContent process shows as a gap.
/// Every 3 s for `duration` seconds each is started once; each completion is logged with its
/// latency and the app state when it started and finished, to tmp/background-bench.jsonl in the app container
/// (the temporary directory: nothing of it is app data).
/// A call that never completes shows up as a missing completion.
@MainActor
enum BackgroundCallBench {
    static let duration: TimeInterval = 200
    private static var player: AVAudioPlayer?
    private static var pages: [WKWebView] = []
    private static var output: FileHandle?
    private static let localScheme = LocalScheme()
    private static let started = Date()

    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["HUMMINGBIRD_BACKGROUND_BENCH"] == "1" else { return }
        Task { @MainActor in await run() }
    }

    private static var state: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private static func log(_ fields: [String: Any]) {
        var fields = fields
        fields["t"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        fields["state_now"] = state
        fields["audio_playing"] = player?.isPlaying ?? false
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        output?.write(data + Data("\n".utf8))
    }

    private static func run() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("background-bench.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        output = try? FileHandle(forWritingTo: url)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: tone())
            player?.numberOfLoops = -1
            player?.volume = 0.05
            player?.play()
        } catch {
            log(["event": "audio_failed", "error": "\(error)"])
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let realmPage = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        realmPage.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let browserConfiguration = WKWebViewConfiguration()
        browserConfiguration.websiteDataStore = .nonPersistent()
        let browserPage = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: browserConfiguration)
        browserPage.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
        let localConfiguration = WKWebViewConfiguration()
        localConfiguration.websiteDataStore = .nonPersistent()
        localConfiguration.setURLSchemeHandler(localScheme, forURLScheme: "hbbench")
        let localPage = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: localConfiguration)
        localPage.load(URLRequest(url: URL(string: "hbbench://local/")!))
        pages = [realmPage, browserPage, localPage]
        for _ in 0..<1000 where realmPage.isLoading || browserPage.isLoading || localPage.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        let ticker = "if (!window.__tick) { window.__last = Date.now(); window.__gap = 0; window.__tick = setInterval(function () { var n = Date.now(); window.__gap = Math.max(window.__gap, n - window.__last); window.__last = n; }, 250); } 0"
        for page in [browserPage, localPage] { _ = try? await page.evaluateJavaScript(ticker) }
        log(["event": "ready", "browser_url": browserPage.url?.absoluteString ?? ""])

        let work = "var s = 0; for (var i = 0; i < 200000; i++) s += Math.sqrt(i); JSON.stringify({ s: s })"
        var round = 0
        while Date().timeIntervalSince(started) < duration {
            round += 1
            let begin = Date(), beginState = state, r = round
            Task.detached(priority: .userInitiated) {
                let began = Date()
                let context = JSContext()
                let value = context?.evaluateScript(work)?.toString()
                let ms = Date().timeIntervalSince(began) * 1000
                await MainActor.run {
                    log(["kind": "a_fresh_jscontext", "round": r, "ms": ms, "ok": value != nil,
                         "state_at_start": beginState, "queued_ms": began.timeIntervalSince(begin) * 1000])
                }
            }
            realmPage.evaluateJavaScript(work, in: nil, in: .world(name: UUID().uuidString)) { result in
                log(["kind": "b_webkit_content_world", "round": r, "ms": Date().timeIntervalSince(begin) * 1000,
                     "ok": (try? result.get()) != nil, "state_at_start": beginState])
            }
            browserPage.callAsyncJavaScript(
                probe("/generate_204"),
                arguments: [:], in: nil, in: .page
            ) { result in
                log(["kind": "c_browser_page", "round": r, "ms": Date().timeIntervalSince(begin) * 1000,
                     "ok": (try? result.get()) != nil, "state_at_start": beginState, "timer_max_gap_ms": gap(result)])
            }
            localPage.callAsyncJavaScript(probe("/ping"), arguments: [:], in: nil, in: .page) { result in
                log(["kind": "d_local_page", "round": r, "ms": Date().timeIntervalSince(begin) * 1000,
                     "ok": (try? result.get()) != nil, "state_at_start": beginState, "timer_max_gap_ms": gap(result)])
            }
            try? await Task.sleep(for: .seconds(3))
        }
        log(["event": "done", "rounds": round])
        player?.stop()
        pages.removeAll()
        try? output?.close()
    }

    /// A same-origin fetch from the page; returns the timer's largest gap since the last call.
    private static func probe(_ path: String) -> String {
        "const r = await fetch('\(path)', { cache: 'no-store' }); const g = window.__gap || 0; window.__gap = 0; return JSON.stringify({ status: r.status, gap: g })"
    }

    private static func gap(_ result: Result<Any, any Error>) -> Double {
        guard let text = try? result.get() as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return -1 }
        return (object["gap"] as? NSNumber)?.doubleValue ?? -1
    }

    /// One second of a quiet 440 Hz tone, as a 16-bit mono WAV.
    private static func tone() -> Data {
        let rate = 44_100
        var samples = Data(capacity: rate * 2)
        for n in 0..<rate {
            let v = Int16(sin(2 * Double.pi * 440 * Double(n) / Double(rate)) * 2_000)
            withUnsafeBytes(of: v.littleEndian) { samples.append(contentsOf: $0) }
        }
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        return header + samples
    }
}

/// Answers the local page (d) and its fetches from the app: no network involved.
@MainActor
private final class LocalScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let isPage = url.path.isEmpty || url.path == "/"
        let body = Data((isPage ? "<!doctype html><html><head><title>local</title></head><body></body></html>" : "ok").utf8)
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": isPage ? "text/html" : "text/plain"])!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
#endif
