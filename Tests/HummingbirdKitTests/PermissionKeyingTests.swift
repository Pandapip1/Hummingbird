import Foundation
import XCTest
@testable import HummingbirdKit

@MainActor
final class PermissionKeyingTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionKeying-\(UUID())", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeLegacy(key: String, used: [String], declined: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: ["used": used, "declined": declined])
        try json.write(to: directory.appendingPathComponent("\(FilePermissionLedger.legacyDigest(key)).json"))
    }

    // MARK: Keying

    func testRebuildWithTheSameSigningIdentifierKeepsTheRecord() {
        let xcodeBuild = FilePermissionLedger(
            directory: directory, instance: "com.eightybps.Hummingbird", legacyInstance: "requirement A"
        )
        xcodeBuild.recordUse(of: .localNetwork)
        // An ad-hoc xtool build: new cdhash and designated requirement, same identifier.
        let xtoolBuild = FilePermissionLedger(
            directory: directory, instance: "com.eightybps.Hummingbird", legacyInstance: "cdhash B"
        )
        XCTAssertTrue(xtoolBuild.hasUsed(.localNetwork))
    }

    func testIdentifiersDifferingOnlyInCaseShareTheRecord() {
        FilePermissionLedger(directory: directory, instance: "com.eightybps.Hummingbird", legacyInstance: "A")
            .recordUse(of: .localNetwork)
        let nixBuild = FilePermissionLedger(directory: directory, instance: "com.eightybps.hummingbird", legacyInstance: "B")
        XCTAssertTrue(nixBuild.hasUsed(.localNetwork))
    }

    func testADifferentSigningIdentifierKeepsItsOwnRecord() {
        let one = FilePermissionLedger(directory: directory, instance: "com.pandapip1.Hummingbird", legacyInstance: "A")
        one.recordUse(of: .localNetwork)
        one.setDeclined("x", true)
        let other = FilePermissionLedger(directory: directory, instance: "com.eightybps.Hummingbird", legacyInstance: "B")
        XCTAssertFalse(other.hasUsed(.localNetwork))
        XCTAssertFalse(other.isDeclined("x"))
    }

    // MARK: Migration

    func testUsesUnderAnyEarlierSignatureKeySuppressTheExplanation() async throws {
        try writeLegacy(key: "designated requirement of an older build", used: ["localNetwork"], declined: ["x"])
        let ledger = FilePermissionLedger(
            directory: directory, instance: "com.eightybps.Hummingbird", legacyInstance: "this build's requirement"
        )
        XCTAssertTrue(ledger.hasUsed(.localNetwork))
        XCTAssertFalse(ledger.isDeclined("x"), "Another build's declines aren't this build's choice")

        let gate = PermissionGate(system: PlatformPermissions(localNetworkStatus: { nil }), ledger: ledger)
        let decision = await gate.authorize(
            .localNetwork, for: LocalNetworkSyncController.feature, origin: .settings, explanation: .localNetworkSync
        )
        XCTAssertEqual(decision, .allowed)
        XCTAssertNil(gate.prompt)
    }

    func testThisBuildsOwnEarlierDeclinesCarryOver() throws {
        try writeLegacy(key: "this build's requirement", used: [], declined: ["x"])
        let ledger = FilePermissionLedger(
            directory: directory, instance: "com.eightybps.Hummingbird", legacyInstance: "this build's requirement"
        )
        XCTAssertTrue(ledger.isDeclined("x"))
        XCTAssertFalse(ledger.hasUsed(.localNetwork))
    }

    func testMigrationRunsOnce() throws {
        try writeLegacy(key: "first", used: [], declined: [])
        let first = FilePermissionLedger(directory: directory, instance: "com.example", legacyInstance: "mine")
        XCTAssertFalse(first.hasUsed(.localNetwork))
        try writeLegacy(key: "second", used: ["localNetwork"], declined: [])
        let reopened = FilePermissionLedger(directory: directory, instance: "com.example", legacyInstance: "mine")
        XCTAssertFalse(reopened.hasUsed(.localNetwork), "Records written after migration belong to old builds still running")
    }

    // MARK: The system's stored decision

    private static let rules = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>$archiver</key><string>NSKeyedArchiver</string>
      <key>$objects</key><array>
        <string>$null</string>
        <dict><key>SigningIdentifier</key><dict><key>CF$UID</key><integer>2</integer></dict>
              <key>MulticastPreferenceSet</key><true/><key>DenyMulticast</key><false/></dict>
        <string>com.eightybps.Hummingbird</string>
        <dict><key>SigningIdentifier</key><dict><key>CF$UID</key><integer>4</integer></dict>
              <key>MulticastPreferenceSet</key><true/><key>DenyMulticast</key><true/></dict>
        <string>com.denied.app</string>
        <dict><key>SigningIdentifier</key><dict><key>CF$UID</key><integer>6</integer></dict>
              <key>MulticastPreferenceSet</key><false/><key>DenyMulticast</key><true/></dict>
        <string>com.unanswered.app</string>
      </array>
      <key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>
      <key>$version</key><integer>100000</integer>
    </dict></plist>
    """.utf8)

    func testStoredDecisionIsReadBySigningIdentifier() {
        XCTAssertEqual(LocalNetworkPrivacyRules.status(for: "com.eightybps.Hummingbird", in: Self.rules), .granted)
        XCTAssertEqual(LocalNetworkPrivacyRules.status(for: "com.eightybps.hummingbird", in: Self.rules), .granted,
                       "The Nix build is signed in lowercase and was not prompted again")
        XCTAssertEqual(LocalNetworkPrivacyRules.status(for: "com.denied.app", in: Self.rules), .denied)
        XCTAssertNil(LocalNetworkPrivacyRules.status(for: "com.unanswered.app", in: Self.rules))
        XCTAssertNil(LocalNetworkPrivacyRules.status(for: "com.missing.app", in: Self.rules))
        XCTAssertNil(LocalNetworkPrivacyRules.status(for: "com.eightybps.Hummingbird", in: Data("garbage".utf8)))
    }

    func testStoredDecisionIsReadFromTheBinaryArchive() throws {
        let plist = try PropertyListSerialization.propertyList(from: Self.rules, format: nil)
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertEqual(LocalNetworkPrivacyRules.status(for: "com.eightybps.Hummingbird", in: binary), .granted)
    }

    func testAStoredGrantSkipsTheExplanationWithoutAnyRecord() async {
        let gate = PermissionGate(
            system: PlatformPermissions(localNetworkStatus: { .granted }), ledger: InMemoryPermissionLedger()
        )
        let decision = await gate.authorize(
            .localNetwork, for: LocalNetworkSyncController.feature, origin: .settings, explanation: .localNetworkSync
        )
        XCTAssertEqual(decision, .allowed)
        XCTAssertNil(gate.prompt)
    }

    func testAStoredDenialReportsDeniedWithoutExplaining() async {
        let gate = PermissionGate(
            system: PlatformPermissions(localNetworkStatus: { .denied }), ledger: InMemoryPermissionLedger()
        )
        let decision = await gate.authorize(
            .localNetwork, for: LocalNetworkSyncController.feature, origin: .settings, explanation: .localNetworkSync
        )
        XCTAssertEqual(decision, .deniedBySystem)
        XCTAssertNil(gate.prompt)
    }
}
