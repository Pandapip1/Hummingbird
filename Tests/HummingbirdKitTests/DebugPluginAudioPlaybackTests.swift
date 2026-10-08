#if !canImport(AVFoundation)
import Foundation
import XCTest
import CGTK
@_spi(SwiftOpenUIBackend) import SwiftOpenUI
@testable import HummingbirdKit

/// Redmine #9 regression test for Linux audio output.
///
/// This plays the debug plugin's 440 Hz fixture through the production path into
/// a private PipeWire/Pulse graph, records the sink monitor, and verifies both
/// non-silence and the expected frequency. Positive controls independently prove
/// that the recorder and GStreamer's stock `pulsesink` work against the same graph.
/// The recorder must be stopped before reading its WAV: `parecord` finalizes the
/// RIFF data length during shutdown, and reading earlier falsely reports zero PCM.
final class DebugPluginAudioPlaybackTests: XCTestCase {
    @MainActor
    func testDebugPluginAudioReachesRealPulseSink() async throws {
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }
        try DebugPluginFixture.ensureTestVideoExists()

        let session = IsolatedAudioSession()
        try session.start()
        defer { session.stop() }
        try session.verifyRecordingPath()
        try session.verifyGStreamerPulsePath()

        let server = try await DebugPluginFixture.startRangeServer(port: 8742)
        defer { ProcessTermination.terminateAndWait(server) }

        let (config, script) = try DebugPluginFixture.loadPlugin()
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        try await runtime.enable()
        defer { Task { await runtime.stop() } }

        let pager = try await runtime.pager("getHome", as: ContentItem.self)
        let item = try XCTUnwrap(pager.initial.first, "the debug plugin's home page should list the plain muxed video first")
        let detailsData = try await runtime.callRaw("getContentDetails", [item.url], kind: "details")
        guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: detailsData) else {
            return XCTFail("expected video details for the debug plugin's home item")
        }

        let options = PlaybackSelector.options(for: details)
        let option = try XCTUnwrap(PlaybackSelector.best(options, maxHeight: 1080, preferAdaptive: true))
        XCTAssertNil(option.audio, "debug-video-1 is muxed; PlaybackSelector should not have split it into separate audio/video sources")

        var backend: GTKMediaBackend? = GTKMediaBackend()
        var failure: String?
        backend!.onFailure = { failure = $0 }
        let widget = VideoPlayer(player: backend!.player).gtkCreateWidget()
        let window = gtk_window_new()!
        gtk_window_set_child(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self),
                             UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWidget.self))
        gtk_widget_set_visible(window, 1)
        defer {
            backend?.stop()
            gtk_window_destroy(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
            backend = nil
            while g_main_context_iteration(nil, 0) != 0 {}
        }

        let request = PlayRequest(video: ResolvedMedia(url: try XCTUnwrap(URL(string: option.video.url)), headers: [:]),
                                   audio: nil, isLive: false)
        // Start observing the monitor before playback. This captures startup
        // audio as well as steady-state playback and avoids making recorder
        // process scheduling part of the media-backend assertion.
        let recording = try session.beginRecording()
        try await backend!.load(request, resumeAt: nil, autoplay: true)

        // Pump real wall-clock time so the real (sync=true) pulsesink actually
        // emits something to record, and give the backend a chance to reach a
        // playing state before asserting anything.
        let deadline = Date().addingTimeInterval(5)
        while backend!.currentTime < 1, Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(failure)
        XCTAssertTrue(backend!.isPlaying)
        XCTAssertGreaterThan(backend!.currentTime, 0.5, "playback should have actually advanced by now")

        let sinkInputs = try session.sinkInputSnapshot()
        let recordDeadline = Date().addingTimeInterval(2)
        while Date() < recordDeadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        session.endRecording()

        let wav = try WAVSamples.read(recording)
        let samples = wav.mono
        XCTAssertGreaterThan(samples.count, 1000,
            "production playback produced no captured PCM. Pulse sink inputs at capture time:\n\(sinkInputs)")

        let rms = AudioAnalysis.rms(samples)
        XCTAssertGreaterThan(rms, 0.02,
            "production playback is effectively silent (rms=\(rms)). Pulse sink inputs at capture time:\n\(sinkInputs)")

        // ~0.5s window for sane Goertzel bin resolution; a generous dominance
        // margin over neighboring control bins, since AAC-encoded pure tones have
        // spectral skirts rather than a single infinitely sharp bin.
        let sampleRate = wav.sampleRate
        let analysisWindow = Array(samples.suffix(sampleRate / 2))
        let target = AudioAnalysis.goertzelMagnitude(analysisWindow, sampleRate: sampleRate, frequency: 440)
        let low = AudioAnalysis.goertzelMagnitude(analysisWindow, sampleRate: sampleRate, frequency: 220)
        let high = AudioAnalysis.goertzelMagnitude(analysisWindow, sampleRate: sampleRate, frequency: 880)
        XCTAssertGreaterThan(target, low * 10, "440 Hz energy should dominate the 220 Hz control bin")
        XCTAssertGreaterThan(target, high * 10, "440 Hz energy should dominate the 880 Hz control bin")
    }
}
#endif
