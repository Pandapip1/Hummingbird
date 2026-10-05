#if !canImport(AVFoundation)
import Foundation
import XCTest
import CGTK
@_spi(SwiftOpenUIBackend) import SwiftOpenUI
@testable import HummingbirdKit

final class GTKPlaybackTests: XCTestCase {
    @MainActor
    func testCustomHTTPHeadersReachGStreamer() async throws {
        gtk_init()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("debug-plugin")
        let python = try pythonExecutable()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = [root.appendingPathComponent("range_server.py").path,
                            "18743", "--bind", "127.0.0.1", "--directory", root.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
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

    private func pythonExecutable() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["HUMMINGBIRD_TEST_PYTHON"],
           FileManager.default.isExecutableFile(atPath: configured) { return configured }
        let lookup = Process()
        let output = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        lookup.arguments = ["sh", "-c", "command -v python3"]
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        lookup.waitUntilExit()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookup.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("custom-header playback fixture requires Python 3; set HUMMINGBIRD_TEST_PYTHON")
        }
        return path
    }
}
#endif
