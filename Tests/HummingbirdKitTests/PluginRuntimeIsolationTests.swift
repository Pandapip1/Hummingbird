import Foundation
import XCTest
@testable import HummingbirdKit

final class PluginRuntimeIsolationTests: XCTestCase {
    @MainActor
    func testBusyJavaScriptAndHostCallbacksLeaveMainActorResponsive() async throws {
        try JSEngines.initializeDefaultRuntimeOnCurrentThread()
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data("{\"name\":\"Thread isolation\"}".utf8))
        let runtime = PluginRuntime(config: config, script: """
            source.enable = function () { log('enable'); };
            source.work = function () {
                log('start');
                const deadline = Date.now() + 300;
                while (Date.now() < deadline) {}
                log('end');
                return 42;
            };
            """, settings: [:], auth: nil, captcha: nil)
        let observation = BusyPluginObservation()
        runtime.onLog = { observation.record($0) }
        let pulse = Task { @MainActor in
            while !Task.isCancelled {
                observation.pulse()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        defer { pulse.cancel() }
        do {
            let result: Int = try await runtime.call("work")
            XCTAssertEqual(result, 42)
            let (messages, mainThreadCallbacks, pulses) = observation.snapshot()
            XCTAssertEqual(messages, ["enable", "start", "end"])
            XCTAssertEqual(mainThreadCallbacks, 0, "plugin lifecycle and native callbacks must run on its worker")
            XCTAssertGreaterThan(pulses, 0, "the main actor must run while the plugin is busy")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }
}

private final class BusyPluginObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var messages: [String] = []
    private var mainThreadCallbacks = 0
    private var pulses = 0

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
        if Thread.isMainThread { mainThreadCallbacks += 1 }
        if message == "start" { running = true }
        if message == "end" { running = false }
    }

    func pulse() {
        lock.lock()
        defer { lock.unlock() }
        if running { pulses += 1 }
    }

    func snapshot() -> ([String], Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (messages, mainThreadCallbacks, pulses)
    }
}
