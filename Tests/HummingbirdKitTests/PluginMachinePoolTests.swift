import Foundation
import XCTest
import PluginEngine
@testable import HummingbirdKit

/// Script caching (`PluginLimits.maximumIdleMachines`): calls reuse JavaScript virtual machines, so a
/// plugin's script is compiled once, but every call still gets a fresh context, and a machine whose
/// call threw or was stopped never serves another call.
extension MaliciousPluginTests {
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testPooledMachinesStillGiveEveryCallAFreshRealm() async throws {
        let rt = try hostile("availability.js", timeouts: .init(call: 5, enable: 5, requestModifier: 1), engine: JSEngines.default)
        let planted = try await rt.call("setMarker", ["stolen-secret"], as: String.self)
        XCTAssertEqual(planted, "stolen-secret")
        try await waitFor { rt.machinePoolForTesting.idle > 0 }
        let reusedBefore = rt.machinePoolForTesting.reused
        let seen = try await rt.call("getMarker", as: String.self)
        XCTAssertEqual(seen, "unset", "a call in a reused machine never sees what an earlier call left on its global")
        XCTAssertGreaterThan(rt.machinePoolForTesting.reused, reusedBefore, "the second call ran in the first call's machine")

        // Concurrent calls take different machines; afterwards, every pooled machine still gives a fresh realm.
        async let busy: String = rt.call("spin", [300])
        async let concurrentSet: String = rt.call("setMarker", ["concurrent"])
        async let concurrentGet: String = rt.call("getMarker")
        let (_, _, concurrentSeen) = try await (busy, concurrentSet, concurrentGet)
        XCTAssertEqual(concurrentSeen, "unset", "concurrent calls cannot see each other")
        try await waitFor { rt.machinePoolForTesting.idle == PluginLimits.maximumIdleMachines }
        for _ in 0..<4 {
            _ = try await rt.call("setMarker", ["again"], as: String.self)
            let later = try await rt.call("getMarker", as: String.self)
            XCTAssertEqual(later, "unset")
        }
        XCTAssertLessThanOrEqual(rt.machinePoolForTesting.idle, PluginLimits.maximumIdleMachines)
    }

    func testAMachineWhoseCallThrewIsDiscarded() async throws {
        let rt = try hostile("availability.js", timeouts: .init(call: 5, enable: 5, requestModifier: 1), engine: JSEngines.default)
        let quick = try await rt.call("quick", as: Int.self)
        XCTAssertEqual(quick, 42)
        try await waitFor { rt.machinePoolForTesting.idle == 1 }
        XCTAssertEqual(rt.machinePoolForTesting.idle, 1)
        do {
            _ = try await rt.call("fail", as: Int.self)
            XCTFail("the call throws")
        } catch {}
        try await waitFor { rt.machinePoolForTesting.dropped == 1 }
        let pool = rt.machinePoolForTesting
        XCTAssertEqual(pool.reused, 1, "the failing call took the pooled machine")
        XCTAssertEqual(pool.dropped, 1, "and it was dropped")
        XCTAssertEqual(pool.idle, 0, "nothing of it is back in the pool")
    }

    func testAMachineWhoseCallMissedItsDeadlineIsDiscarded() async throws {
        let rt = try hostile("availability.js", timeouts: .init(call: 0.5, enable: 5, requestModifier: 1), engine: JSEngines.default)
        _ = try await rt.call("quick", as: Int.self)
        try await waitFor { rt.machinePoolForTesting.idle == 1 }
        // The watchdog takes the overrunning context out of service; when its script returns, the
        // context closes and its machine goes with it.
        do {
            _ = try await rt.call("spin", [600], as: String.self)
            XCTFail("the call misses its deadline")
        } catch PluginError.timeout {}
        try await waitFor { rt.machinePoolForTesting.dropped == 1 }
        XCTAssertEqual(rt.machinePoolForTesting.dropped, 1)
        XCTAssertEqual(rt.machinePoolForTesting.idle, 0)
    }
}
