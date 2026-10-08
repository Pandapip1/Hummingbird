import Foundation
import XCTest

/// Owns one disposable PipeWire graph — its own `pipewire` + `pipewire-pulse` +
/// `wireplumber`, a `module-null-sink` target, and nothing else — so a test can
/// exercise real audio playback without touching (or depending on) the host's real
/// desktop audio session.
///
/// `XDG_RUNTIME_DIR` alone does **not** stop WirePlumber from enumerating the host's
/// real ALSA/Bluetooth/V4L hardware (confirmed empirically: a default-profile
/// WirePlumber pointed at a scratch runtime dir still listed the host's real mic and
/// camera). The `hummingbird-test` profile in
/// `Tests/debug-plugin/wireplumber.conf.d/99-hummingbird-isolated.conf` disables
/// those monitor components; this is what actually makes the instance isolated.
final class IsolatedAudioSession {
    private static let sinkName = "hb_test_sink"

    private let workDir: URL
    private let runtimeDir: URL
    private var pipewire: Process?
    private var wireplumber: Process?
    private var pipewirePulse: Process?
    private var dbusDaemonPID: Int32?
    private var dbusSessionAddress: String?
    private var previousPulseServer: String?
    private var started = false
    private var activeRecorder: Process?

    private var pulseServer: String { "unix:\(runtimeDir.path)/pulse/native" }

    init() {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-audio-session-\(UUID().uuidString)")
        runtimeDir = workDir.appendingPathComponent("run")
    }

    /// Starts the scratch graph, creates the null sink, and points `PULSE_SERVER`
    /// (in *this* process's own environment — `pulsesink` connects via libpulse
    /// in-process, the same way `GTKPlaybackTests` already `setenv`s
    /// `SWIFT_OPENUI_GST_FAKE_AUDIO`) at it. Throws `XCTSkip` if any required tool
    /// is missing, so the test degrades to a skip rather than a false failure on a
    /// machine without a PipeWire stack.
    func start() throws {
        precondition(!started)
        let configHome = workDir.appendingPathComponent("config")
        let profileDir = configHome.appendingPathComponent("wireplumber/wireplumber.conf.d")
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDir.path)
        let profileSource = DebugPluginFixture.directory
            .appendingPathComponent("wireplumber.conf.d/99-hummingbird-isolated.conf")
        try FileManager.default.copyItem(at: profileSource, to: profileDir.appendingPathComponent("99-hummingbird-isolated.conf"))

        var env = ProcessInfo.processInfo.environment
        env["XDG_RUNTIME_DIR"] = runtimeDir.path
        env["XDG_CONFIG_HOME"] = configHome.path
        let dbus = try startPrivateDBusSession()
        dbusDaemonPID = dbus.pid
        dbusSessionAddress = dbus.address
        env["DBUS_SESSION_BUS_ADDRESS"] = dbus.address

        pipewire = try spawn(tool: "pipewire", arguments: [], environment: env, log: workDir.appendingPathComponent("pipewire.log"))
        try waitForSocket(runtimeDir.appendingPathComponent("pipewire-0"), process: pipewire!)

        wireplumber = try spawn(tool: "wireplumber", arguments: ["-p", "hummingbird-test"], environment: env,
                                 log: workDir.appendingPathComponent("wireplumber.log"))
        // No socket of its own to poll for; give the session manager a moment to
        // attach and apply its profile before pipewire-pulse (and anything that
        // depends on routing policy) comes up.
        Thread.sleep(forTimeInterval: 1)

        pipewirePulse = try spawn(tool: "pipewire-pulse", arguments: [], environment: env,
                                   log: workDir.appendingPathComponent("pipewire-pulse.log"))
        try waitForSocket(runtimeDir.appendingPathComponent("pulse/native"), process: pipewirePulse!)

        try pactl(["load-module", "module-null-sink", "sink_name=\(Self.sinkName)",
                   "sink_properties=device.description=HummingbirdTestSink"])
        try pactl(["set-default-sink", Self.sinkName])

        previousPulseServer = getenv("PULSE_SERVER").map { String(cString: $0) }
        setenv("PULSE_SERVER", pulseServer, 1)
        started = true
    }

    /// Mandatory positive control: play a known tone through the **Pulse**
    /// protocol into the scratch sink and
    /// confirm the recorder actually sees it, *before* any Hummingbird code touches
    /// the graph. Without this, a silent capture later is ambiguous between
    /// "Hummingbird produced no audio" (the bug) and "the scratch graph's
    /// monitor/sink wiring doesn't carry audio at all" (a rig problem) — those must
    /// never be conflated, so this throws `XCTSkip` rather than letting the real
    /// test run on an unproven rig.
    func verifyRecordingPath() throws {
        let tone = workDir.appendingPathComponent("control-tone.wav")
        try run(tool: "gst-launch-1.0", arguments: [
            "-q", "audiotestsrc", "wave=sine", "freq=440", "num-buffers=150", "samplesperbuffer=960", "!",
            "audioconvert", "!", "audio/x-raw,format=F32LE,rate=44100,channels=1", "!", "wavenc", "!",
            "filesink", "location=\(tone.path)",
        ])
        let recording = try record(playing: tone)
        let samples = try WAVSamples.read(recording).mono
        let rms = AudioAnalysis.rms(samples)
        guard rms > 0.05 else {
            throw XCTSkip("audio rig unavailable: the isolated PipeWire instance's null sink did not carry a known test tone to its recorder (rms=\(rms)) — this is a rig problem, not a Hummingbird bug")
        }
    }

    /// Separates the desktop Pulse protocol from GStreamer's Pulse sink. The
    /// main regression test must not accidentally attribute a generic
    /// `pulsesink`/PipeWire failure to Hummingbird's media backend.
    func verifyGStreamerPulsePath() throws {
        let (recorder, capture) = try startRecorder()
        Thread.sleep(forTimeInterval: 0.3)
        let player = try spawn(tool: "gst-launch-1.0", arguments: [
            "-q", "audiotestsrc", "wave=sine", "freq=440", "num-buffers=150", "!",
            "audioconvert", "!", "audio/x-raw,format=S16LE,rate=48000,channels=2", "!", "pulsesink",
        ], environment: envWithPulseServer(), log: workDir.appendingPathComponent("gst-pulsesink.log"))
        Thread.sleep(forTimeInterval: 0.4)
        let snapshot = try sinkInputSnapshot()
        ProcessTermination.wait(for: player)
        Thread.sleep(forTimeInterval: 0.3)
        ProcessTermination.terminateAndWait(recorder)
        let samples = try WAVSamples.read(capture).mono
        guard AudioAnalysis.rms(samples) > 0.02 else {
            throw NSError(domain: "HummingbirdTests", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "GStreamer's standalone pulsesink produced no audio in the proven private PipeWire/Pulse graph. Stream state while running:\n\(snapshot)",
            ])
        }
    }

    /// Plays `url` through `paplay` (blocking for its natural duration) while
    /// recording from the null sink's monitor via `parecord`. Both use the
    /// server's Pulse protocol: a native `pw-play` control cannot validate the
    /// boundary where #9 occurs.
    func record(playing url: URL) throws -> URL {
        let (recorder, capture) = try startRecorder()
        Thread.sleep(forTimeInterval: 0.3)
        let player = try spawn(tool: "paplay", arguments: ["--server", pulseServer, url.path],
                               environment: envWithPulseServer(), log: workDir.appendingPathComponent("paplay.log"))
        ProcessTermination.wait(for: player)
        Thread.sleep(forTimeInterval: 0.3)
        // `parecord` finalizes the RIFF data length only while handling its
        // shutdown. Reading before it exits makes a non-empty recording look
        // like a valid zero-frame WAV.
        ProcessTermination.terminateAndWait(recorder)
        return capture
    }

    /// Starts recording whatever is already playing into the sink elsewhere in the
    /// test (i.e. Hummingbird's own playback, not something this method starts).
    /// The recorder receives from the isolated server's Pulse monitor. `pulsesink`
    /// owns a `pa_threaded_mainloop`, so the caller does not need to pump GTK or GLib
    /// to make audio output progress.
    func beginRecording() throws -> URL {
        let (recorder, capture) = try startRecorder()
        activeRecorder = recorder
        return capture
    }

    func endRecording() {
        guard let recorder = activeRecorder else { return }
        ProcessTermination.terminateAndWait(recorder)
        activeRecorder = nil
    }

    /// Captures Pulse's authoritative view of the client while playback is live.
    /// Kept in the integration test failure so routing, corking and negotiated
    /// buffer state are evidence rather than inferred from a silent monitor.
    func sinkInputSnapshot() throws -> String {
        try runOutput(tool: "pactl", arguments: ["--server", pulseServer, "list", "sink-inputs"],
                      environment: envWithPulseServer())
    }

    private func startRecorder() throws -> (Process, URL) {
        let capture = workDir.appendingPathComponent("capture-\(UUID().uuidString).wav")
        let process = try spawn(tool: "parecord",
                                 arguments: ["-d", "\(Self.sinkName).monitor", "--format=s16le", "--file-format=wav", capture.path],
                                 environment: envWithPulseServer(), log: workDir.appendingPathComponent("parecord.log"))
        return (process, capture)
    }

    func stop() {
        guard started else { return }
        endRecording()
        if let previousPulseServer { setenv("PULSE_SERVER", previousPulseServer, 1) } else { unsetenv("PULSE_SERVER") }
        for process in [pipewirePulse, wireplumber, pipewire] {
            guard let process else { continue }
            ProcessTermination.terminateAndWait(process)
        }
        if let dbusDaemonPID {
            kill(dbusDaemonPID, SIGTERM)
            self.dbusDaemonPID = nil
        }
        // Set HB_KEEP_AUDIO_SESSION_LOGS=1 to inspect a failing run's pipewire/
        // wireplumber/pipewire-pulse/parecord logs and captured WAVs afterward.
        if ProcessInfo.processInfo.environment["HB_KEEP_AUDIO_SESSION_LOGS"] == nil {
            try? FileManager.default.removeItem(at: workDir)
        } else {
            FileHandle.standardError.write(Data("IsolatedAudioSession: kept \(workDir.path)\n".utf8))
        }
        started = false
    }

    // MARK: -

    private func envWithPulseServer() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PULSE_SERVER"] = pulseServer
        env["XDG_RUNTIME_DIR"] = runtimeDir.path
        if let dbusSessionAddress { env["DBUS_SESSION_BUS_ADDRESS"] = dbusSessionAddress }
        return env
    }

    /// `pipewire-pulse` exports `org.pulseaudio.Server` over the session bus. A
    /// scratch runtime directory alone still inherits the desktop bus, where the
    /// real server already owns that name. Give the three scratch daemons their own
    /// bus so a failed ownership request cannot change routing or test behaviour.
    private func startPrivateDBusSession() throws -> (address: String, pid: Int32) {
        let process = Process()
        let output = Pipe()
        let socket = runtimeDir.appendingPathComponent("dbus-session")
        process.executableURL = try URL(fileURLWithPath: which("dbus-daemon"))
        process.arguments = [
            "--session", "--fork", "--print-address=1", "--print-pid=1",
            "--address=unix:path=\(socket.path)",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // `--fork` writes these two lines only after the daemon is listening and
        // closes stdout before the short-lived launcher exits. Reading to EOF is
        // therefore the synchronization point; Foundation's Process termination
        // callback is unreliable for this particular fork-and-exit program.
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        guard lines.count >= 2, let pid = Int32(lines[1]) else {
            throw XCTSkip("private dbus-daemon did not report its address and PID")
        }
        return (String(lines[0]), pid)
    }

    private func pactl(_ arguments: [String]) throws {
        try run(tool: "pactl", arguments: ["--server", pulseServer] + arguments, environment: envWithPulseServer())
    }

    private func waitForSocket(_ path: URL, process: Process) throws {
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: path.path) { return }
            guard process.isRunning else { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("expected socket \(path.lastPathComponent) never appeared — isolated audio session failed to start")
    }

    @discardableResult
    private func spawn(tool: String, arguments: [String], environment: [String: String], log: URL) throws -> Process {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: which(tool))
        process.arguments = arguments
        process.environment = environment
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    @discardableResult
    private func run(tool: String, arguments: [String], environment: [String: String]? = nil) throws -> Process {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: which(tool))
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        ProcessTermination.wait(for: process)
        return process
    }

    private func runOutput(tool: String, arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = try URL(fileURLWithPath: which(tool))
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard ProcessTermination.wait(for: process), process.terminationStatus == 0 else {
            throw XCTSkip("'\(tool)' failed while inspecting the isolated Pulse server")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func which(_ name: String) throws -> String {
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
            throw XCTSkip("'\(name)' is not on PATH — the isolated audio session needs pipewire, wireplumber, pulseaudio (pactl/parecord) and gstreamer's gst-launch-1.0")
        }
        return path
    }
}
