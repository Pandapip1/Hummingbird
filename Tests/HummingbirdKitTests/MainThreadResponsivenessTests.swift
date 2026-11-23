import Foundation
import Synchronization
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
        // Each load makes a fresh engine; measure the player's own work with a quiet one
        // (creating the platform engine is prewarmed at launch: prewarmMediaBackend).
        model.makeBackend = { QuietBackend() }
        let details = try Self.manySourceDetails()
        let runtime = try Self.runtime()
        let library = makeTestAppModel().library
        let probe = MainThreadProbe()
        probe.start()
        let clock = ContinuousClock()
        let selectionStart = clock.now
        let options = PlaybackSelector.options(for: details, preferredLanguage: "en")
        print("[responsiveness] options=\(options.count) selection=\(selectionStart.duration(to: clock.now))")
        for round in 0..<3 {
            let started = clock.now
            await model.load(details: details, runtime: runtime, library: library, sourceURL: "https://example.test/v/\(round)")
            print("[responsiveness] load \(round) took \(started.duration(to: clock.now)) worst so far \(probe.worstSoFar)")
            XCTAssertNotNil(model.selected, "a source was chosen (\(model.errorMessage ?? "no error"))")
            // Let the seek bar's content be built (off the main actor).
            try await Task.sleep(for: .milliseconds(50))
        }
        let worst = probe.stop()
        model.teardown()
        await runtime.stop()
        XCTAssertGreaterThan(probe.samples, 5, "the probe ran")
        let stack = probe.worstStack
        if !stack.isEmpty { print("[responsiveness] main thread during the longest wait (\(worst)):\n  " + stack.joined(separator: "\n  ")) }
        XCTAssertLessThan(worst, Self.budget,
                          "the main thread was busy for \(worst) at once while preparing; it was running:\n"
                          + stack.prefix(16).joined(separator: "\n"))
    }

    /// The seek bar's lanes for a long video (thousands of downloaded ranges)
    /// are built off the main actor; building them is still quick.
    func testLongVideoSeekBarContentIsCheap() {
        var chapters: [PlaybackChapter] = []
        for index in 0..<300 {
            let start = Double(index) * 36
            let type = index % 10 == 0 ? 5 : 0
            chapters.append(PlaybackChapter(name: "Chapter \(index)", timeStart: start, timeEnd: start + 36, type: type))
        }
        let clock = ContinuousClock()
        let started = clock.now
        _ = PlaybackScrubber.content(pipeline: .empty, duration: 10_800, chapters: chapters, isLive: false)
        let elapsed: Duration = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, Duration.milliseconds(50))
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
        return PluginRuntime(
            approval: testLoadApproval(config),
            config: config,
            script: try ScriptSignature.check("source.enable = function() {};", for: config),
            settings: [:], auth: nil, captcha: nil
        )
    }
}

/// Measures, from another thread, how long the main thread takes to run a
/// block it is sent: the longest such wait is the longest stretch it was busy.
/// A wait that passes `sampleAfter` samples what the main thread is running
/// (its stack), so a failure says what kept it busy instead of only how long.
private final class MainThreadProbe: Sendable {
    private struct State {
        var running = false
        var worst: Duration = .zero
        var worstStack: [String] = []
        var count = 0
    }
    private let state = Mutex(State())
    private static let sampleAfter: Duration = .milliseconds(30)

    var samples: Int { state.withLock { $0.count } }
    var worstSoFar: Duration { state.withLock { $0.worst } }
    /// The main thread's stack during the longest wait that passed `sampleAfter`.
    var worstStack: [String] { state.withLock { $0.worstStack } }

    /// Call on the main thread (it names the thread to sample).
    func start() {
        let main = MainThreadSampler.currentThread()
        state.withLock { $0.running = true }
        Thread.detachNewThread { [self] in
            let clock = ContinuousClock()
            while state.withLock({ $0.running }) {
                let sent = clock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                var stack: [String] = []
                if answered.wait(timeout: .now() + 0.03) == .timedOut {
                    stack = MainThreadSampler.stack(of: main)
                    // Waits as long as it takes: a busy main thread is what is measured.
                    while answered.wait(timeout: .now() + 0.1) == .timedOut {
                        if !state.withLock({ $0.running }) { return }
                    }
                }
                let waited = sent.duration(to: clock.now)
                state.withLock {
                    if waited > $0.worst {
                        $0.worst = waited
                        if waited >= Self.sampleAfter { $0.worstStack = stack }
                    }
                    $0.count += 1
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    /// Stops and returns the longest wait.
    func stop() -> Duration {
        state.withLock {
            $0.running = false
            return $0.worst
        }
    }
}

/// Samples another thread's stack: suspends it, walks its frame pointers,
/// resumes it, and only then symbolizes (symbol lookup takes locks the
/// suspended thread may hold).
private enum MainThreadSampler {
    #if canImport(Darwin) && arch(arm64)
    typealias ThreadPort = thread_act_t

    static func currentThread() -> ThreadPort { pthread_mach_thread_np(pthread_self()) }

    static func stack(of thread: ThreadPort, depth: Int = 32) -> [String] {
        var addresses: [UInt] = []
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var registers = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &registers) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            // Return addresses can carry pointer-authentication bits above 47.
            let mask: UInt = 0x0000_7FFF_FFFF_FFFF
            addresses = [UInt(registers.__pc) & mask, UInt(registers.__lr) & mask]
            var frame = UInt(registers.__fp)
            while frame != 0, frame & 7 == 0, addresses.count < depth,
                  let pointer = UnsafePointer<UInt>(bitPattern: frame) {
                let next = pointer[0], returnAddress = pointer[1] & mask
                guard returnAddress != 0 else { break }
                addresses.append(returnAddress)
                guard next > frame else { break }
                frame = next
            }
        }
        thread_resume(thread)
        return addresses.map(symbol)
    }

    private static func symbol(_ address: UInt) -> String {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else {
            return String(address, radix: 16)
        }
        let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "" } ?? ""
        let name = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image) \(name)"
    }
    #else
    typealias ThreadPort = Int
    static func currentThread() -> ThreadPort { 0 }
    static func stack(of thread: ThreadPort) -> [String] { [] }
    #endif
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
