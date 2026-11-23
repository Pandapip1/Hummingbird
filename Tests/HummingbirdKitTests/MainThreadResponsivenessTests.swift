import Foundation
import XCTest
import AdvancedVideoPlayerKit
@testable import HummingbirdKit

/// The user's diagnostics showed main-thread stalls of 250–600 ms while a
/// video prepared. Preparing a video must leave the main thread free: what
/// runs there (selection, state) is quick, and what is slow (downloads,
/// playlists, the loopback server, asset loading, the seek bar's lanes) runs
/// elsewhere. A probe on another thread measures how long the main thread
/// takes to answer while it happens.
@MainActor
final class MainThreadResponsivenessTests: XCTestCase {
    /// Longest the main thread may be busy at a stretch while a video prepares.
    private static let budget: Duration = .milliseconds(50)

    func testPreparingAVideoNeverBlocksTheMainThread() async throws {
        let backend = QuietBackend()
        let model = makeTestPlayerModel(backend: backend)
        let details = try Self.manySourceDetails()
        let runtime = try Self.runtime()
        let library = makeTestAppModel().library
        let probe = MainThreadProbe()
        probe.start()
        for round in 0..<3 {
            await model.load(details: details, runtime: runtime, library: library, sourceURL: "https://example.test/v/\(round)")
            XCTAssertNotNil(model.selected, "a source was chosen")
            // Let the seek bar's content be built (off the main actor).
            try await Task.sleep(for: .milliseconds(50))
        }
        let worst = probe.stop()
        model.teardown()
        await runtime.stop()
        XCTAssertGreaterThan(probe.samples, 5, "the probe ran")
        XCTAssertLessThan(worst, Self.budget, "the main thread was busy for \(worst) at once while preparing")
    }

    /// The seek bar's lanes for a long video (thousands of downloaded ranges)
    /// are built off the main actor; building them is still quick.
    func testLongVideoSeekBarContentIsCheap() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = PlaybackScrubber.content(pipeline: .empty, duration: 10_800, chapters: (0..<300).map {
                PlaybackChapter(name: "Chapter \($0)", timeStart: Double($0) * 36, timeEnd: Double($0 + 1) * 36, type: $0 % 10 == 0 ? 5 : 0)
            }, isLive: false)
        }
        XCTAssertLessThan(elapsed, .milliseconds(50))
    }

    // MARK: fixtures

    private static func manySourceDetails() throws -> VideoDetails {
        let heights = [144, 240, 360, 480, 720, 1080, 1440, 2160]
        var video: [String] = []
        for (index, height) in heights.enumerated() {
            for codec in ["avc1.640028", "vp09.00.40.08", "av01.0.08M.08"] {
                video.append(#"{"plugin_type":"VideoUrlRangeSource","url":"https://x/v\#(index)-\#(codec)","height":\#(height),"width":\#(height * 16 / 9),"container":"video/mp4","codec":"\#(codec)","bitrate":\#(height * 4000),"itagId":\#(100 + index)}"#)
            }
        }
        var audio: [String] = []
        for language in ["en", "de", "fr", "es", "ja", "pt-BR"] {
            for bitrate in [48_000, 128_000] {
                audio.append(#"{"plugin_type":"AudioUrlRangeSource","url":"https://x/a-\#(language)-\#(bitrate)","container":"audio/mp4","codec":"mp4a.40.2","bitrate":\#(bitrate),"language":"\#(language)","itagId":140}"#)
            }
        }
        let subtitles = (0..<40).map { #"{"name":"Subtitles \#($0)","language":"en","url":"https://x/s\#($0).vtt","format":"text/vtt"}"# }
        let json = """
        {"contentType":1,"name":"V","url":"u","id":{"pluginId":"p","value":"v"},"description":"","duration":3600,
         "video":{"isUnMuxed":true,"videoSources":[\(video.joined(separator: ","))],"audioSources":[\(audio.joined(separator: ","))]},
         "subtitles":[\(subtitles.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(VideoDetails.self, from: Data(json.utf8))
    }

    private static func runtime() throws -> PluginRuntime {
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"Probe","id":"main-thread-probe","scriptUrl":"x.js","version":1}"#.utf8)
        )
        return PluginRuntime(config: config, script: "source.enable = function() {};", settings: [:], auth: nil, captcha: nil)
    }
}

/// Measures, from another thread, how long the main thread takes to run a
/// block it is sent: the longest such wait is the longest stretch it was busy.
private final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var worst: Duration = .zero
    private var count = 0
    private var thread: Thread?

    var samples: Int { lock.withLock { count } }

    func start() {
        lock.withLock { running = true }
        let thread = Thread { [self] in
            let clock = ContinuousClock()
            while lock.withLock({ running }) {
                let sent = clock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                // Waits as long as it takes: a busy main thread is what is measured.
                while answered.wait(timeout: .now() + 0.1) == .timedOut {
                    if !lock.withLock({ running }) { return }
                }
                let waited = sent.duration(to: clock.now)
                lock.withLock {
                    worst = max(worst, waited)
                    count += 1
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        self.thread = thread
        thread.start()
    }

    /// Stops and returns the longest wait.
    func stop() -> Duration {
        lock.withLock {
            running = false
            return worst
        }
    }
}

private final class QuietBackend: MediaBackend {
    var currentTime = 0.0
    var isPlaying: Bool { false }
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() {}
}
