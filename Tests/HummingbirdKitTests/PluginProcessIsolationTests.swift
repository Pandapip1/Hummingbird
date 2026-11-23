import Foundation
import Synchronization
import XCTest
import PluginEngine
#if !os(Linux)
import CJSCExecutionLimit
#endif
@testable import HummingbirdKit

/// Stopping runaway plugins with the strongest enforcement a build has (`PluginExecutionLimits`):
/// killing the plugin's host process, or JavaScriptCore's own time limit. The host process here is
/// `hummingbird-plugin-host` from this build, started as a child process (the macOS app uses the
/// same protocol through its XPC service). Nothing reaches the network.
#if os(macOS) || os(Linux)
extension MaliciousPluginTests {
    static var hostExecutable: URL? {
        let candidates = [
            Bundle(for: MaliciousPluginTests.self).bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ].map { $0.appendingPathComponent("hummingbird-plugin-host") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func hostEngine() throws -> RemoteJSEngine {
        let executable = try XCTUnwrap(Self.hostExecutable, "build hummingbird-plugin-host (swift build --build-tests builds it)")
        let engine = RemoteJSEngine(launcher: SubprocessPluginHostLauncher(executable: executable))
        addTeardownBlock { engine.terminate() }
        return engine
    }

    func testHostProcessRunsScriptsAndAnswersHostCallsThroughTheApp() throws {
        let engine = try hostEngine()
        let calls = HostCallLog()
        let context = try engine.makeContext { name, a, b in
            calls.record(name)
            return "app:\(name):\(a):\(b)"
        }
        defer { context.close() }
        XCTAssertEqual(try context.evaluate("__hostCall('http', 'x', 'y') + ' ' + (40 + 2)", name: "probe"), "app:http:x:y 42")
        XCTAssertEqual(calls.names, ["http"])
        // Only __hostCall reaches the app; the host process has nothing else to offer a script.
        XCTAssertEqual(try context.evaluate("typeof require + typeof process + typeof fetch + typeof XMLHttpRequest", name: "probe"),
                       "undefinedundefinedundefinedundefined")
        XCTAssertThrowsError(try context.evaluate("throw new Error('boom')", name: "probe"))
        XCTAssertTrue(engine.isRunning)
    }

    func testARunawayPluginInAHostProcessIsKilledAtItsDeadline() async throws {
        let engine = try hostEngine()
        let rt = try hostile("availability.js", engine: engine)
        _ = try await rt.enable()
        let started = Date()
        do {
            _ = try await rt.call("spin", [60_000], as: String.self)
            XCTFail("a pure loop must be stopped")
        } catch PluginError.timeout {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "stopped at the deadline, not when the loop ends")
        XCTAssertFalse(engine.isRunning, "the plugin's host process was killed")
        // Nothing keeps spinning: the plugin is not left with stuck contexts, and works again.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(rt.isSuspended)
        for _ in 0..<3 {
            do { _ = try await rt.call("spin", [60_000], as: String.self) } catch PluginError.timeout {}
        }
        XCTAssertFalse(rt.isSuspended, "killed loops never pile up into a suspended plugin")
        let quick = try await rt.call("quick", as: Int.self)
        XCTAssertEqual(quick, 42)
    }

    func testContainmentIsTheSameInAHostProcess() async throws {
        let engine = try hostEngine()
        let rt = try hostile("network.js", engine: engine)
        let refused = try await rt.call("probe", ["http://169.254.169.254/latest", [String: String]()], as: Probe.self)
        XCTAssertNotNil(refused.error, "the host process reaches the network only through the app's contained HTTP")
        XCTAssertTrue(Stub.seen.isEmpty)
        let allowed = try await rt.call("probe", ["https://allowed.test/ok", [String: String]()], as: Probe.self)
        XCTAssertEqual(allowed.code, 200)
        let first = try hostile("availability.js", engine: engine)
        _ = try await first.call("setMarker", ["planted"], as: String.self)
        let seen = try await first.call("getMarker", as: String.self)
        XCTAssertEqual(seen, "unset", "every call still gets a fresh context")
    }

    #if !os(Linux)
    /// The JavaScriptCore time limit, as non-App-Store builds install it (Apps/iOS/DirectDistribution.swift).
    private struct TestTimeLimit: JSCExecutionTimeLimiter {
        func setLimit(_ seconds: Double?, globalContext: OpaquePointer) {
            if let seconds { hb_set_execution_time_limit(globalContext, seconds) } else { hb_clear_execution_time_limit(globalContext) }
        }
    }

    func testJavaScriptCoreTimeLimitStopsALoopInProcessWithoutLeavingAThread() async throws {
        PluginExecutionLimits.installEngineTimeLimit(TestTimeLimit())
        addTeardownBlock { PluginExecutionLimits.reset() }
        XCTAssertEqual(PluginExecutionLimits.enforcement, .engineTimeLimit)
        let rt = try hostile("availability.js", engine: JSEngines.default)
        _ = try await rt.enable()
        for _ in 0..<3 {
            let started = Date()
            do {
                _ = try await rt.call("spin", [60_000], as: String.self)
                XCTFail("a pure loop must be stopped")
            } catch PluginError.timeout {}
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        }
        // The engine stopped each loop, so no context was abandoned still running.
        XCTAssertFalse(rt.isSuspended)
        let quick = try await rt.call("quick", as: Int.self)
        XCTAssertEqual(quick, 42)
    }
    #endif

    func testEnforcementReportsTheStrongestAvailable() throws {
        PluginExecutionLimits.reset()
        addTeardownBlock { PluginExecutionLimits.reset() }
        XCTAssertEqual(PluginExecutionLimits.enforcement, .abandonment)
        let executable = try XCTUnwrap(Self.hostExecutable)
        PluginExecutionLimits.installProcessIsolation(SubprocessPluginHostLauncher(executable: executable))
        XCTAssertEqual(PluginExecutionLimits.enforcement, .processTermination)
        XCTAssertTrue(PluginExecutionLimits.makeEngine() is RemoteJSEngine)
    }
}
#endif

final class HostCallLog: Sendable {
    private let list = Mutex<[String]>([])
    func record(_ name: String) { list.withLock { $0.append(name) } }
    var names: [String] { list.withLock { $0 } }
}
