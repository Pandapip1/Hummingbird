#if !canImport(AVFoundation) || BACKEND_GTK
import Foundation
import XCTest
import CGTK
@_spi(SwiftOpenUIBackend) import SwiftOpenUI
@testable import HummingbirdKit

final class GTKPlaybackTests: XCTestCase {
    @MainActor
    func testOfficialYouTubeProgressiveRangeStreamPlays() async throws {
        guard let path = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_PLUGIN_DIR"] else {
            throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_PLUGIN_DIR to an official plugin checkout")
        }
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }
        let root = URL(fileURLWithPath: path)
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(contentsOf: root.appendingPathComponent("YoutubeConfig.json"))
        )
        let script = try String(contentsOf: root.appendingPathComponent("YoutubeScript.js"), encoding: .utf8)
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }
        let videoURL = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_VIDEO_URL"]
            ?? "https://www.youtube.com/watch?v=ukE4nf9WeQU"
        let data = try await runtime.callRaw("getContentDetails", [videoURL], kind: "details")
        guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: data) else {
            return XCTFail("Expected YouTube video details")
        }
        let options = PlaybackSelector.options(for: details)
        guard let option = PlaybackSelector.best(options, maxHeight: 1080, preferAdaptive: true),
              option.kind == .progressive, let audio = option.audio else {
            return XCTFail("Expected separate progressive YouTube video and audio")
        }
        let resolvedVideo = try await resolve(option.video, runtime: runtime)
        let resolvedAudio = try await resolve(audio, runtime: runtime)
        for media in [resolvedVideo, resolvedAudio] {
            var request = URLRequest(url: media.url)
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            for (name, value) in media.headers { request.setValue(value, forHTTPHeaderField: name) }
            let (probe, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            print("[youtube range probe] status=\(http.statusCode) bytes=\(probe.count) type=\(contentType) range=\(contentRange)")
            XCTAssertTrue((200...299).contains(http.statusCode))
            XCTAssertEqual(String(decoding: probe.dropFirst(4).prefix(4), as: UTF8.self), "ftyp")
        }

        let previousFakeAudio = getenv("SWIFT_OPENUI_GST_FAKE_AUDIO").map { String(cString: $0) }
        setenv("SWIFT_OPENUI_GST_FAKE_AUDIO", "1", 1)
        defer {
            if let previousFakeAudio { setenv("SWIFT_OPENUI_GST_FAKE_AUDIO", previousFakeAudio, 1) }
            else { unsetenv("SWIFT_OPENUI_GST_FAKE_AUDIO") }
        }
        var backend: GTKMediaBackend? = GTKMediaBackend()
        var failure: String?
        backend!.onFailure = { failure = $0 }
        let widget = VideoPlayer(player: backend!.player).gtkCreateWidget()
        let window = gtk_window_new()!
        gtk_window_set_child(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self),
                             UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWidget.self))
        defer {
            backend?.stop()
            gtk_window_destroy(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
            backend = nil
            while g_main_context_iteration(nil, 0) != 0 {}
        }
        try await backend!.load(
            PlayRequest(video: resolvedVideo, audio: resolvedAudio, isLive: false),
            resumeAt: nil, autoplay: true
        )
        let deadline = Date().addingTimeInterval(15)
        while backend!.currentTime < 0.5, failure == nil, Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThan(backend!.currentTime, 0.5)
    }

    @MainActor
    func testOfficialYouTubeGeneratedStreamPlaysAndSeeks() async throws {
        guard let path = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_PLUGIN_DIR"] else {
            throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_PLUGIN_DIR to an official plugin checkout")
        }
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }
        let root = URL(fileURLWithPath: path)
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(contentsOf: root.appendingPathComponent("YoutubeConfig.json"))
        )
        let script = try String(contentsOf: root.appendingPathComponent("YoutubeScript.js"), encoding: .utf8)
        let runtime = PluginRuntime(
            config: config, script: script,
            settings: ["useUMP": "true", "use_native_ump": "false"],
            auth: nil, captcha: nil
        )
        defer { Task { await runtime.stop() } }
        let videoURL = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_VIDEO_URL"]
            ?? "https://www.youtube.com/watch?v=ukE4nf9WeQU"
        let (manifest, executor) = try await generatedPresentation(
            runtime, url: videoURL, sourceType: "DashManifestRawSource"
        )
        let (audioManifest, audioExecutor) = try await generatedPresentation(
            runtime, url: videoURL, sourceType: "DashManifestRawAudioSource"
        )
        let playbackURL = try await PluginMediaProxy.shared.register(
            videoManifest: manifest, videoRuntime: runtime, videoExecutor: executor,
            audioManifest: audioManifest, audioRuntime: runtime, audioExecutor: audioExecutor
        )

        let previousFakeAudio = getenv("SWIFT_OPENUI_GST_FAKE_AUDIO").map { String(cString: $0) }
        setenv("SWIFT_OPENUI_GST_FAKE_AUDIO", "1", 1)
        defer {
            if let previousFakeAudio { setenv("SWIFT_OPENUI_GST_FAKE_AUDIO", previousFakeAudio, 1) }
            else { unsetenv("SWIFT_OPENUI_GST_FAKE_AUDIO") }
        }
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
        try await backend!.load(
            PlayRequest(video: ResolvedMedia(url: playbackURL, headers: [:]), audio: nil, isLive: false),
            resumeAt: nil, autoplay: true
        )
        let playbackDeadline = Date().addingTimeInterval(15)
        while backend!.currentTime < 0.5, failure == nil, Date() < playbackDeadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThan(backend!.currentTime, 0.5)
        backend!.seek(to: 5)
        let seekDeadline = Date().addingTimeInterval(10)
        while backend!.currentTime < 5.25, failure == nil, Date() < seekDeadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(backend!.currentTime, 5.25)
        backend!.seek(to: 1)
        let backwardSeekDeadline = Date().addingTimeInterval(10)
        while backend!.currentTime < 1.25, failure == nil, Date() < backwardSeekDeadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThan(backend!.currentTime, 1.25)
    }

    @MainActor
    private func generatedPresentation(
        _ runtime: PluginRuntime, url: String, sourceType: String
    ) async throws -> (String, Int) {
        for attempt in 0..<2 {
            let data = try await runtime.callRaw("getContentDetails", [url], kind: "details")
            guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: data) else {
                throw PluginError.execution("Expected YouTube video details")
            }
            let sources = sourceType == "DashManifestRawAudioSource"
                ? details.audioSources : details.videoSources
            guard let source = sources.first(where: {
                $0.pluginType == sourceType && $0.container.lowercased().contains("mp4")
            }), let handle = source.handle else {
                throw PluginError.execution("Expected a generated MP4 \(sourceType)")
            }
            do {
                let manifest = try PluginRuntime.decode(
                    String.self, from: try await runtime.callHandle(handle, "generate")
                )
                guard let executor = try await runtime.handleFromCall(handle, "getRequestExecutor") else {
                    throw PluginError.execution("Expected a generated-media request executor")
                }
                return (manifest, executor.handle)
            } catch let PluginError.reloadRequired(_, reloadData) where attempt == 0 {
                await runtime.reload(reloadData: reloadData)
            }
        }
        throw PluginError.execution("Generated playback still requested a reload")
    }

    @MainActor
    private func resolve(_ source: MediaSource, runtime: PluginRuntime) async throws -> ResolvedMedia {
        guard var url = URL(string: source.url) else { throw PluginError.execution("Invalid media URL") }
        var headers: [String: String] = [:]
        if let modifier = source.requestModifier {
            let data = try await runtime.callHandle(
                modifier.handle, "modifyRequest", [source.url, [String: String]()]
            )
            if let request = try? PluginRuntime.decode(TestModifiedRequest.self, from: data) {
                if let value = request.url, let modifiedURL = URL(string: value) { url = modifiedURL }
                headers = request.headers ?? [:]
            }
        }
        return ResolvedMedia(url: url, headers: headers)
    }

    @MainActor
    func testCancelledInstalledLoadClearsCurrentItemAfterReplacementFails() async throws {
        let gate = InstalledItemGate()
        var buildCount = 0
        let backend = GTKMediaBackend(
            itemFactory: { _, _ in
                buildCount += 1
                if buildCount == 2 { throw PluginError.execution("replacement failed") }
                return AVPlayerItem(asset: AVAsset())
            },
            didInstallItem: { _ in try await gate.suspendAfterInstallation() }
        )
        let media = ResolvedMedia(url: try XCTUnwrap(URL(string: "https://example.com/video.mp4")), headers: [:])
        let request = PlayRequest(video: media, audio: nil, isLive: false)

        let first = Task { try? await backend.load(request, resumeAt: nil, autoplay: true) }
        await gate.waitForInstallation()
        XCTAssertNotNil(backend.player.currentItem)

        do {
            try await backend.load(request, resumeAt: nil, autoplay: true)
            XCTFail("Expected replacement construction to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "replacement failed")
        }
        first.cancel()
        await first.value

        XCTAssertNil(backend.player.currentItem)
        XCTAssertTrue(backend.tracks.isEmpty)
    }

    @MainActor
    func testMissingMediaReportsFailureBeforeAnyVideoFrame() async throws {
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }
        var backend: GTKMediaBackend? = GTKMediaBackend()
        let widget = VideoPlayer(player: backend!.player).gtkCreateWidget()
        let window = gtk_window_new()!
        gtk_window_set_child(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self),
                             UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWidget.self))
        defer {
            backend?.stop()
            gtk_window_destroy(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
            backend = nil
            while g_main_context_iteration(nil, 0) != 0 {}
        }
        var failure: String?
        backend!.onFailure = { failure = $0 }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try await backend!.load(
            PlayRequest(video: ResolvedMedia(url: missing, headers: [:]), audio: nil, isLive: false),
            resumeAt: nil, autoplay: true)
        let deadline = Date().addingTimeInterval(2)
        while failure == nil, Date() < deadline {
            // Track discovery used to pop and discard ERROR bus messages.
            _ = backend!.tracks
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(try XCTUnwrap(failure).isEmpty)
        XCTAssertFalse(backend!.isPlaying)
        XCTAssertEqual(backend!.currentTime, 0)
    }

    @MainActor
    func testCustomHTTPHeadersReachGStreamer() async throws {
        try TestDisplaySession.start()
        gtk_init()
        try DebugPluginFixture.ensureTestVideoExists()
        let server = try await DebugPluginFixture.startRangeServer(port: 18743)
        defer {
            ProcessTermination.terminateAndWait(server)
        }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18743/header-video.mp4"))
        let audioURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18743/header-audio.mp4"))
        for _ in 0..<30 {
            if let response = try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse,
               response.statusCode == 403 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let previousFakeAudio = getenv("SWIFT_OPENUI_GST_FAKE_AUDIO").map { String(cString: $0) }
        setenv("SWIFT_OPENUI_GST_FAKE_AUDIO", "1", 1)
        defer {
            if let previousFakeAudio { setenv("SWIFT_OPENUI_GST_FAKE_AUDIO", previousFakeAudio, 1) }
            else { unsetenv("SWIFT_OPENUI_GST_FAKE_AUDIO") }
        }
        var backend: GTKMediaBackend? = GTKMediaBackend()
        let widget = VideoPlayer(player: backend!.player).gtkCreateWidget()
        let window = gtk_window_new()!
        gtk_window_set_child(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self),
                             UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWidget.self))
        try await backend!.load(
            PlayRequest(video: ResolvedMedia(url: url, headers: ["X-Debug-Video": "allowed"]),
                        audio: ResolvedMedia(url: audioURL, headers: ["X-Debug-Audio": "allowed"]),
                        isLive: false),
            resumeAt: nil,
            autoplay: true
        )
        backend!.setPlaybackRate(2)
        for _ in 0..<10 {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(backend!.currentTime, 1.4)
        let positionBeforeRateChange = backend!.currentTime
        backend!.setPlaybackRate(0.5)
        XCTAssertEqual(backend!.currentTime, positionBeforeRateChange, accuracy: 0.25)
        for _ in 0..<5 {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(backend!.currentTime, positionBeforeRateChange + 0.1)
        let positionBeforeRestoringRate = backend!.currentTime
        backend!.setPlaybackRate(2)
        XCTAssertEqual(backend!.currentTime, positionBeforeRestoringRate, accuracy: 0.25)
        backend!.seek(to: 4)
        XCTAssertEqual(backend!.currentTime, 4, accuracy: 0.25)
        for _ in 0..<5 {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(backend!.currentTime, 4.7)
        backend!.seek(to: 4.6)
        XCTAssertEqual(backend!.currentTime, 4.6, accuracy: 0.25)
        for _ in 0..<5 {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(backend!.currentTime, 5.1)

        let muxedURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18743/test.mp4"))
        try await backend!.load(
            PlayRequest(video: ResolvedMedia(url: muxedURL, headers: [:]), audio: nil, isLive: false),
            resumeAt: nil,
            autoplay: true
        )
        for _ in 0..<30 where backend!.tracks.isEmpty {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(backend!.tracks.contains { $0.kind == .video })
        XCTAssertTrue(backend!.tracks.contains { $0.kind == .audio })
        if let audioTrack = backend!.tracks.first(where: { $0.kind == .audio }) {
            backend!.selectTrack(audioTrack)
        }

        let nonRangeURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18743/no-range.mp4"))
        try await backend!.load(
            PlayRequest(video: ResolvedMedia(url: nonRangeURL, headers: [:]),
                        audio: ResolvedMedia(url: nonRangeURL, headers: [:]),
                        isLive: false),
            resumeAt: nil,
            autoplay: true
        )
        for _ in 0..<30 where backend!.currentTime < 0.25 {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        backend!.seek(to: 4)
        XCTAssertEqual(backend!.currentTime, 4, accuracy: 0.25)
        for _ in 0..<50 where backend!.currentTime < 4.5 {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let positionAfterFallbackSeek = backend!.currentTime
        XCTAssertGreaterThan(positionAfterFallbackSeek, 4.5)
        for _ in 0..<5 {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(backend!.currentTime, positionAfterFallbackSeek + 0.25)
        backend?.stop()
        gtk_window_destroy(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
        backend = nil
        while g_main_context_iteration(nil, 0) != 0 {}
    }
}

private struct TestModifiedRequest: Decodable {
    let url: String?
    let headers: [String: String]?
}

@MainActor
private final class InstalledItemGate {
    private var installed = false
    private var installationWaiter: CheckedContinuation<Void, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?

    func waitForInstallation() async {
        if installed { return }
        await withCheckedContinuation { installationWaiter = $0 }
    }

    func suspendAfterInstallation() async throws {
        installed = true
        installationWaiter?.resume()
        installationWaiter = nil
        try await withTaskCancellationHandler {
            await withCheckedContinuation { suspensionWaiter = $0 }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.suspensionWaiter?.resume()
                self?.suspensionWaiter = nil
            }
        }
    }
}
#endif
