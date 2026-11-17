import Foundation
import XCTest
@testable import HummingbirdKit

/// Task 34: a slow plugin call never blocks another; handles go back to the
/// context that made them; sequential calls keep sharing one warm context.
final class PluginContextPoolTests: XCTestCase {
    private let script = """
    source.enable = function () { source.counter = 0; };
    source.slow = function () { var end = Date.now() + 1500; while (Date.now() < end) {} return "slow"; };
    source.fast = function () { return "fast"; };
    source.bump = function () { source.counter += 1; return source.counter; };
    source.makeThing = function () { return { size: 42, getSize: function () { return this.size; } }; };
    source.getHome = function () { return new ContentPager([], false); };
    source.search = function () { return new ContentPager([], false); };
    source.isChannelUrl = function () { return false; };
    source.getChannel = function () { return null; };
    source.getChannelContents = function () { return new ContentPager([], false); };
    source.isContentDetailsUrl = function () { return false; };
    source.getContentDetails = function () { return null; };
    """

    private func runtime() throws -> PluginRuntime {
        let config = try JSONDecoder().decode(
            PluginConfig.self, from: Data(#"{"name":"Pool","id":"pool-test","scriptUrl":"x.js","version":1}"#.utf8)
        )
        return PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
    }

    func testASlowCallDoesNotBlockAnother() async throws {
        let runtime = try runtime()
        defer { Task { await runtime.stop() } }
        _ = try await runtime.enable()
        let slow = Task { try await runtime.call("slow", as: String.self) }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        let fast = try await runtime.call("fast", as: String.self)
        let waited = started.duration(to: .now)
        XCTAssertEqual(fast, "fast")
        XCTAssertLessThan(waited, .milliseconds(1_000), "the fast call ran beside the slow one")
        XCTAssertEqual(runtime.contextCount, 2)
        let slowResult = try await slow.value
        XCTAssertEqual(slowResult, "slow")
    }

    func testHandlesGoBackToTheContextThatMadeThem() async throws {
        let runtime = try runtime()
        defer { Task { await runtime.stop() } }
        _ = try await runtime.enable()
        let slow = Task { try await runtime.call("slow", as: String.self) }
        try await Task.sleep(for: .milliseconds(200))
        // Made on the second context while the first is busy.
        let thing = try XCTUnwrap(try await runtime.handleFromSource("makeThing"))
        XCTAssertGreaterThan(thing.handle, PluginRuntime.handleSpan, "handles come from that context's own range")
        let size = await runtime.intProperty(handle: thing.handle, "size")
        XCTAssertEqual(size, 42)
        _ = try await slow.value
    }

    func testSequentialCallsShareOneWarmContext() async throws {
        let runtime = try runtime()
        defer { Task { await runtime.stop() } }
        _ = try await runtime.enable()
        let first = try await runtime.call("bump", as: Int.self)
        let second = try await runtime.call("bump", as: Int.self)
        XCTAssertEqual([first, second], [1, 2], "state persists between calls, as in Grayjay")
        XCTAssertEqual(runtime.contextCount, 1)
    }

    func testContextsAreBounded() async throws {
        let runtime = try runtime()
        defer { Task { await runtime.stop() } }
        _ = try await runtime.enable()
        let tasks = (0..<6).map { _ in Task { try await runtime.call("slow", as: String.self) } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(runtime.contextCount, PluginRuntime.maximumContexts)
        for task in tasks { _ = try await task.value }
    }
}
