import Foundation
import XCTest
@testable import HummingbirdKit

@MainActor
private final class PromptingSystem: SystemPermissions {
    let presentsPrompts = true
    func status(of resource: ProtectedResource) -> PermissionStatus {
        resource == .localNetwork ? .unreported : .undetermined
    }
    func request(_ resource: ProtectedResource) async -> Bool { true }
}

@MainActor
final class PluginLocalNetworkAccessTests: XCTestCase {
    private var ledger: InMemoryPermissionLedger!
    private var gate: PermissionGate!

    override func setUp() async throws {
        ledger = InMemoryPermissionLedger()
        gate = PermissionGate(system: PromptingSystem(), ledger: ledger)
    }

    private func waitForPrompt(file: StaticString = #filePath, line: UInt = #line) async throws -> PermissionGate.Prompt {
        for _ in 0..<1_000 {
            if let prompt = gate.prompt { return prompt }
            await Task.yield()
        }
        return try XCTUnwrap(gate.prompt, "No explanation was shown", file: file, line: line)
    }

    func testPluginRequestToLANHostExplainsFirstAndDeclinesPerHost() async throws {
        let access = PluginLocalNetworkAccess(gate: gate)
        let lan = try XCTUnwrap(URL(string: "http://192.168.1.20:8096/Items"))
        let check = Task { await access.authorize(lan, source: "Jellyfin", origin: .settings) }
        let prompt = try await waitForPrompt()
        XCTAssertTrue(prompt.explanation.message.contains("Jellyfin"))
        gate.respond(.offOnThisDevice)
        let allowed = await check.value
        XCTAssertFalse(allowed)
        XCTAssertTrue(ledger.isDeclined(PluginLocalNetworkAccess.feature(host: "192.168.1.20")))
        XCTAssertFalse(ledger.isDeclined(LocalNetworkSyncController.feature))

        let publicHost = await access.authorize(
            try XCTUnwrap(URL(string: "https://example.com/")), source: "Web", origin: .settings
        )
        XCTAssertTrue(publicHost)
        XCTAssertNil(gate.prompt)
    }

    func testLocalNetworkAddressClassification() throws {
        let local = ["http://192.168.0.2/", "http://10.1.2.3:80/", "http://172.20.0.1/", "http://169.254.1.1/",
                     "http://nas.local/", "http://nas/", "http://[fe80::1%25en0]/", "http://[fd12::1]/",
                     "http://[::ffff:192.168.1.1]/"]
        let notLocal = ["http://127.0.0.1/", "http://localhost:8080/", "http://[::1]/", "https://example.com/",
                        "http://172.32.0.1/", "http://8.8.8.8/", "http://[2001:db8::1]/"]
        for string in local {
            XCTAssertTrue(LocalNetworkAddress.isLocalNetwork(try XCTUnwrap(URL(string: string))), string)
        }
        for string in notLocal {
            XCTAssertFalse(LocalNetworkAddress.isLocalNetwork(try XCTUnwrap(URL(string: string))), string)
        }
    }


    func testAddingALANSourceAsksTheSystemAtOnceAndLiftsAnEarlierBlock() async throws {
        let access = PluginLocalNetworkAccess(gate: gate)
        ledger.setDeclined(PluginLocalNetworkAccess.feature(host: "nas.local"), true)
        let allowed = await access.authorize(
            try XCTUnwrap(URL(string: "http://nas.local/Config.json")), source: nil, origin: .userAction
        )
        XCTAssertTrue(allowed)
        XCTAssertNil(gate.prompt)
        XCTAssertFalse(ledger.isDeclined(PluginLocalNetworkAccess.feature(host: "nas.local")))
        XCTAssertTrue(ledger.hasUsed(.localNetwork))
    }
}
