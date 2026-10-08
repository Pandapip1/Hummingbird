import Foundation
import XCTest
@testable import HummingbirdKit

/// Shared helpers for tests that exercise `Tests/debug-plugin/`: loading the plugin
/// itself, making sure its video fixture exists, and serving it over HTTP.
enum DebugPluginFixture {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // HummingbirdKitTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("debug-plugin")
    }

    static func loadPlugin() throws -> (PluginConfig, String) {
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(contentsOf: directory.appendingPathComponent("DebugPlugin.json")))
        let script = try String(contentsOf: directory.appendingPathComponent("DebugPlugin.js"), encoding: .utf8)
        return (config, script)
    }

    /// `test.mp4` is gitignored and generated on first use (see `serve.sh`); nothing
    /// previously regenerated it for an automated run that had never called
    /// `serve.sh` by hand, so both `GTKPlaybackTests` and the new audio test call
    /// this before relying on it existing.
    static func ensureTestVideoExists() throws {
        let video = directory.appendingPathComponent("test.mp4")
        guard !FileManager.default.fileExists(atPath: video.path) else { return }
        let ffmpegArgs = [
            "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=10:size=320x240:rate=15",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
            "-pix_fmt", "yuv420p", "-c:v", "libx264", "-c:a", "aac", "-shortest", video.path,
        ]
        if let ffmpeg = try? which("ffmpeg") {
            try run(ffmpeg, ffmpegArgs)
        } else if let nix = try? which("nix") {
            try run(nix, ["shell", "nixpkgs#ffmpeg", "--command", "ffmpeg"] + ffmpegArgs)
        } else {
            throw XCTSkip("generating Tests/debug-plugin/test.mp4 needs ffmpeg (directly or via `nix shell nixpkgs#ffmpeg`)")
        }
        guard FileManager.default.fileExists(atPath: video.path) else {
            throw XCTSkip("ffmpeg ran but did not produce Tests/debug-plugin/test.mp4")
        }
    }

    static func pythonExecutable() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["HUMMINGBIRD_TEST_PYTHON"],
           FileManager.default.isExecutableFile(atPath: configured) { return configured }
        guard let path = try? which("python3"), FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("this fixture requires Python 3; set HUMMINGBIRD_TEST_PYTHON")
        }
        return path
    }

    /// Spawns `range_server.py` on `port` and waits until it actually answers.
    /// `throw XCTSkip` if the port is already bound by something else (e.g. a
    /// developer's own `serve.sh`) — that's an environment conflict, not a product
    /// bug, and shouldn't show up as a red test.
    static func startRangeServer(port: UInt16) async throws -> Process {
        let python = try pythonExecutable()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = [directory.appendingPathComponent("range_server.py").path,
                             String(port), "--bind", "127.0.0.1", "--directory", directory.path]
        server.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        server.standardError = errorPipe
        try server.run()
        let url = URL(string: "http://127.0.0.1:\(port)/DebugPlugin.json")!
        for _ in 0..<50 {
            if let response = try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse,
               response.statusCode == 200 {
                return server
            }
            if !server.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        ProcessTermination.terminateAndWait(server)
        let stderr = String(decoding: errorPipe.fileHandleForReading.availableData, as: UTF8.self)
        if stderr.lowercased().contains("address already in use") {
            throw XCTSkip("port \(port) already in use — stop serve.sh (or any other debug-plugin server) before running this test")
        }
        throw XCTSkip("range_server.py on 127.0.0.1:\(port) never came up: \(stderr)")
    }

    private static func which(_ name: String) throws -> String {
        let lookup = Process()
        let output = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        lookup.arguments = ["sh", "-c", "command -v \(name)"]
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        ProcessTermination.wait(for: lookup)
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookup.terminationStatus == 0, !path.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        return path
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        ProcessTermination.wait(for: process)
        return process
    }
}
