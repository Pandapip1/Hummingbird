import ATAppSync
import Foundation
import XCTest
@testable import HummingbirdKit

@MainActor
private final class FakeSystemPermissions: SystemPermissions {
    var presentsPrompts = true
    var statuses: [ProtectedResource: PermissionStatus] = [.localNetwork: .unreported, .camera: .undetermined]
    var grants = true
    private(set) var requests: [ProtectedResource] = []

    func status(of resource: ProtectedResource) -> PermissionStatus { statuses[resource] ?? .undetermined }
    func request(_ resource: ProtectedResource) async -> Bool {
        requests.append(resource)
        return grants
    }
}

/// Stands in for DNS-SD: counts every touch of the protected API.
@MainActor
private final class FakeTransport {
    private(set) var exposeCount = 0
    private(set) var concealCount = 0
    var failure: (any Error)?

    var transport: LocalNetworkSyncController.Transport {
        .init(
            expose: { [self] in
                exposeCount += 1
                if let failure { throw failure }
            },
            conceal: { [self] in concealCount += 1 }
        )
    }
}

@MainActor
final class PermissionGateTests: XCTestCase {
    private var system: FakeSystemPermissions!
    private var ledger: InMemoryPermissionLedger!
    private var gate: PermissionGate!
    private var network: FakeTransport!
    private var persisted: [Bool] = []

    override func setUp() async throws {
        system = FakeSystemPermissions()
        ledger = InMemoryPermissionLedger()
        gate = PermissionGate(system: system, ledger: ledger)
        network = FakeTransport()
        persisted = []
    }

    private func makeSync(enabled: Bool) -> LocalNetworkSyncController {
        LocalNetworkSyncController(
            isEnabled: enabled, gate: gate, transport: network.transport,
            persist: { [unowned self] in persisted.append($0) }
        )
    }

    private func waitForPrompt(file: StaticString = #filePath, line: UInt = #line) async throws -> PermissionGate.Prompt {
        for _ in 0..<1_000 {
            if let prompt = gate.prompt { return prompt }
            await Task.yield()
        }
        return try XCTUnwrap(gate.prompt, "No explanation was shown", file: file, line: line)
    }

    // MARK: Local Network Sync

    func testSyncedSettingExplainsBeforeTouchingTheNetwork() async throws {
        let sync = makeSync(enabled: true)
        let launch = Task { await sync.applyStoredSetting() }

        let prompt = try await waitForPrompt()
        XCTAssertEqual(prompt.resource, .localNetwork)
        XCTAssertEqual(prompt.feature, LocalNetworkSyncController.feature)
        XCTAssertEqual(prompt.explanation, .localNetworkSync)
        XCTAssertEqual(sync.state, .awaitingPermission)
        XCTAssertEqual(network.exposeCount, 0, "DNS-SD must not start before the user has seen why")
        XCTAssertFalse(ledger.hasUsed(.localNetwork))

        gate.respond(.continue)
        await launch.value

        XCTAssertEqual(network.exposeCount, 1)
        XCTAssertEqual(sync.state, .available)
        XCTAssertTrue(ledger.hasUsed(.localNetwork))
        XCTAssertEqual(persisted, [], "Applying the stored setting must not rewrite it")
    }

    func testUserTurningSyncOnStartsAtOnceWithoutExplanation() async {
        let sync = makeSync(enabled: false)
        await sync.applyStoredSetting()
        XCTAssertEqual(network.exposeCount, 0)

        await sync.setEnabled(true)

        XCTAssertNil(gate.prompt)
        XCTAssertEqual(network.exposeCount, 1)
        XCTAssertEqual(sync.state, .available)
        XCTAssertEqual(persisted, [true])
        XCTAssertTrue(ledger.hasUsed(.localNetwork))
    }

    func testDecliningKeepsSyncOffHereAndLeavesTheSharedSettingAlone() async throws {
        let sync = makeSync(enabled: true)
        let launch = Task { await sync.applyStoredSetting() }
        _ = try await waitForPrompt()
        gate.respond(.offOnThisDevice)
        await launch.value

        XCTAssertEqual(network.exposeCount, 0)
        XCTAssertEqual(sync.state, .offOnThisDevice)
        XCTAssertTrue(sync.isEnabled, "The shared setting stays on for other instances")
        XCTAssertFalse(sync.isOnHere)
        XCTAssertEqual(persisted, [])

        // Next launch, the shared setting is still on: no explanation, no network.
        let relaunched = makeSync(enabled: true)
        await relaunched.applyStoredSetting()
        XCTAssertNil(gate.prompt)
        XCTAssertEqual(network.exposeCount, 0)
        XCTAssertEqual(relaunched.state, .offOnThisDevice)

        // Turning it on here is a direct request: it starts and clears the decline.
        await relaunched.setEnabled(true)
        XCTAssertEqual(network.exposeCount, 1)
        XCTAssertEqual(relaunched.state, .available)
        XCTAssertFalse(ledger.isDeclined(LocalNetworkSyncController.feature))
        XCTAssertEqual(persisted, [], "It was already on; only this instance changed")
    }

    func testDeclineHoldsAfterAnotherFeatureUsedTheLocalNetwork() async {
        ledger.setDeclined(LocalNetworkSyncController.feature, true)
        ledger.recordUse(of: .localNetwork)
        let sync = makeSync(enabled: true)
        await sync.applyStoredSetting()
        XCTAssertEqual(sync.state, .offOnThisDevice)
        XCTAssertEqual(network.exposeCount, 0)
    }

    func testDeclineIsForgottenOnceTheSharedSettingIsOff() async {
        ledger.setDeclined(LocalNetworkSyncController.feature, true)
        let sync = makeSync(enabled: false)
        await sync.applyStoredSetting()
        XCTAssertFalse(ledger.isDeclined(LocalNetworkSyncController.feature))
    }

    func testNotNowPostponesWithoutRemembering() async throws {
        let sync = makeSync(enabled: true)
        let launch = Task { await sync.applyStoredSetting() }
        _ = try await waitForPrompt()
        gate.respond(.notNow)
        await launch.value

        XCTAssertEqual(sync.state, .postponed)
        XCTAssertEqual(network.exposeCount, 0)
        XCTAssertFalse(ledger.isDeclined(LocalNetworkSyncController.feature))

        await sync.retry()
        XCTAssertEqual(network.exposeCount, 1)
        XCTAssertEqual(sync.state, .available)
    }

    func testEarlierUseSkipsTheExplanation() async {
        ledger.recordUse(of: .localNetwork)
        let sync = makeSync(enabled: true)
        await sync.applyStoredSetting()
        XCTAssertNil(gate.prompt)
        XCTAssertEqual(network.exposeCount, 1)
    }

    func testPolicyDenialStillCountsAsUse() async {
        network.failure = InstanceMessagingError.localNetworkDiscoveryFailed(operation: .browse, code: -65570)
        let sync = makeSync(enabled: false)
        await sync.setEnabled(true)
        guard case .failed = sync.state else { return XCTFail("Expected failure, got \(sync.state)") }
        XCTAssertTrue(ledger.hasUsed(.localNetwork), "The system has had its chance to prompt")
    }

    func testTurningOffWhileExplainingNeverTouchesTheNetwork() async throws {
        let sync = makeSync(enabled: true)
        let launch = Task { await sync.applyStoredSetting() }
        _ = try await waitForPrompt()
        await sync.setEnabled(false)
        gate.respond(.continue)
        await launch.value
        XCTAssertEqual(network.exposeCount, 0)
        XCTAssertEqual(sync.state, .disabled)
        XCTAssertEqual(persisted, [false])
    }

    func testPlatformWithoutPromptsPassesStraightThrough() async {
        system.presentsPrompts = false
        let sync = makeSync(enabled: true)
        await sync.applyStoredSetting()
        XCTAssertNil(gate.prompt)
        XCTAssertEqual(network.exposeCount, 1)
        XCTAssertFalse(ledger.hasUsed(.localNetwork), "Nothing to remember where nothing prompts")
    }

    func testAppModelLaunchWithSyncedSettingWaitsForConsent() async throws {
        let model = AppModel(
            stores: makeTestStores(),
            localProfileID: UUID(), localNetworkSyncEnabled: true, permissions: gate
        )
        let prompt = try await waitForPrompt()
        XCTAssertEqual(prompt.feature, LocalNetworkSyncController.feature)
        XCTAssertEqual(model.localNetworkSync.state, .awaitingPermission)
        XCTAssertFalse(model.localNetworkSync.isActive)
        gate.respond(.offOnThisDevice)
        for _ in 0..<1_000 where model.localNetworkSync.state != .offOnThisDevice { await Task.yield() }
        XCTAssertEqual(model.localNetworkSync.state, .offOnThisDevice)
    }

    // MARK: Gate

    func testCameraFromATapAsksTheSystemAtOnce() async {
        let decision = await gate.authorize(.camera, for: "qr-scanner", origin: .userAction, explanation: .qrScanner)
        XCTAssertEqual(decision, .allowed)
        XCTAssertEqual(system.requests, [.camera])
        XCTAssertNil(gate.prompt)
    }

    func testCameraFromSettingsExplainsBeforeAsking() async throws {
        let ask = Task { await gate.authorize(.camera, for: "qr-scanner", origin: .settings, explanation: .qrScanner) }
        _ = try await waitForPrompt()
        XCTAssertEqual(system.requests, [])
        gate.respond(.continue)
        let decision = await ask.value
        XCTAssertEqual(decision, .allowed)
        XCTAssertEqual(system.requests, [.camera])
    }

    func testGrantedOrDeniedStatusNeedsNoExplanation() async {
        system.statuses[.camera] = .granted
        let granted = await gate.authorize(.camera, for: "qr-scanner", origin: .settings, explanation: .qrScanner)
        XCTAssertEqual(granted, .allowed)
        system.statuses[.camera] = .denied
        let denied = await gate.authorize(.camera, for: "qr-scanner", origin: .settings, explanation: .qrScanner)
        XCTAssertEqual(denied, .deniedBySystem)
        XCTAssertNil(gate.prompt)
        XCTAssertEqual(system.requests, [])
    }

    func testOneConsentCoversEveryFeatureWaitingOnTheResource() async throws {
        let sync = Task {
            await gate.authorize(.localNetwork, for: "a", origin: .settings, explanation: .localNetworkSync)
        }
        _ = try await waitForPrompt()
        let plugin = Task {
            await gate.authorize(.localNetwork, for: "b", origin: .settings, explanation: .localNetworkSync)
        }
        for _ in 0..<100 { await Task.yield() }
        gate.respond(.continue)
        let first = await sync.value
        let second = await plugin.value
        XCTAssertEqual(first, .allowed)
        XCTAssertEqual(second, .allowed)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(gate.prompt, "The second feature needs no modal of its own")
    }

    func testFileLedgerIsPerInstance() throws {
        let directory = makeTestDirectory("PermissionLedger")
        let xcode = FilePermissionLedger(directory: directory, instance: "identifier A")
        xcode.recordUse(of: .localNetwork)
        xcode.setDeclined("x", true)

        let reopened = FilePermissionLedger(directory: directory, instance: "identifier A")
        XCTAssertTrue(reopened.hasUsed(.localNetwork))
        XCTAssertTrue(reopened.isDeclined("x"))

        let xtool = FilePermissionLedger(directory: directory, instance: "identifier B")
        XCTAssertFalse(xtool.hasUsed(.localNetwork))
        XCTAssertFalse(xtool.isDeclined("x"))
    }
}
