import ATProtoKit
import Crypto
import Foundation
import SwiftOpenUI
import XCTest
@testable import HummingbirdKit

/// The source-access policy's rules for every kind of source, age answer and
/// system parental-controls state, plus the profile's age bound, parents'
/// approvals and login confinement. Only
/// in-memory stores are used.
final class SourceAccessPolicyTests: XCTestCase {
    private let youTubeID = "35ae969a-a7db-11ed-afa1-0242ac120002"

    private func config(_ id: String, name: String = "Source") throws -> PluginConfig {
        try JSONDecoder().decode(PluginConfig.self, from: Data(#"{"name":"\#(name)","id":"\#(id)"}"#.utf8))
    }

    private func curated(_ minimumAge: Int?, category: SourceCategory = .generalVideo,
                         restricted: [String: String] = [:]) -> SourceClassification {
        // Each restricted setting: its safe value, raising the source to 18+
        // otherwise.
        SourceClassification(pluginID: "curated", isCurated: true, category: category,
                             explicitMinimumAge: minimumAge,
                             settingRatings: restricted.map { SettingRating(setting: $0.key, values: [], minimumAge: 18,
                                                                            safeValue: $0.value) })
    }

    private let ages: [(String, AgeEvidence)] = [
        ("under 13", .range(lower: 0, upper: 12)),
        ("13-15", .range(lower: 13, upper: 15)),
        ("16-17", .range(lower: 16, upper: 17)),
        ("adult", .range(lower: 18, upper: nil)),
        ("declined", .declined),
        ("unknown", .unknown),
    ]

    // MARK: classification

    func testRatingIsExplicitElseCategoryDefault() {
        XCTAssertEqual(curated(nil, category: .generalVideo).minimumAge, 18)
        XCTAssertEqual(curated(nil, category: .education).minimumAge, 0)
        XCTAssertEqual(curated(13, category: .generalVideo).minimumAge, 13)
        XCTAssertEqual(SourceClassification.unlisted("x").minimumAge, 18)
    }

    /// The pinned key of the reviewed YouTube plugin.
    private var youTubeKey: String { CuratedSourceDatabase.shared.entry(for: youTubeID)!.publicKey }

    /// The reviewed YouTube plugin's config, signed with its pinned key.
    private func reviewedYouTube(name: String = "YouTube") throws -> PluginConfig {
        var signed = try config(youTubeID, name: name)
        signed.scriptPublicKey = youTubeKey
        return signed
    }

    func testCuratedListMatchesIdAndPinnedKey() throws {
        let database = CuratedSourceDatabase.shared
        var lookalike = try reviewedYouTube()
        let reviewed = database.classification(for: lookalike)
        XCTAssertTrue(reviewed.isCurated)
        XCTAssertEqual(reviewed.minimumAge, 16, "YouTube is 16+ with age- and controversy-restricted videos off")
        XCTAssertEqual(reviewed.restrictedModeSettings["allowAgeRestricted"], "false")
        XCTAssertFalse(database.classification(for: try self.config("other")).isCurated)

        lookalike.scriptPublicKey = "OTHER"
        XCTAssertFalse(database.classification(for: lookalike).isCurated, "a lookalike signed by someone else is unlisted")
        lookalike.scriptPublicKey = nil
        XCTAssertFalse(database.classification(for: lookalike).isCurated, "an unsigned lookalike is unlisted")
    }

    func testBundledListIsWellFormed() {
        let list = CuratedSourceDatabase.bundled
        XCTAssertEqual(list.format, CuratedSourceList.supportedFormat)
        XCTAssertGreaterThan(list.version, 0)
        XCTAssertFalse(list.entries.isEmpty)
        XCTAssertEqual(Set(list.entries.map(\.pluginID)).count, list.entries.count, "ids are unique")
        for entry in list.entries {
            XCTAssertFalse(entry.publicKey.isEmpty, "\(entry.name) has a pinned key")
            XCTAssertNotNil(URL(string: entry.configURL)?.host, entry.name)
            XCTAssertTrue([0, 13, 16, 18].contains(entry.classification.minimumAge), entry.name)
        }
        // General video platforms default to 18+ (category default).
        XCTAssertTrue(list.entries.filter { $0.category == .generalVideo && $0.minimumAge == nil }
            .allSatisfy { $0.classification.minimumAge == 18 })
    }

    // MARK: rated settings

    func testRatedSettingsRaiseTheEffectiveRating() throws {
        let source = CuratedSourceDatabase.shared.classification(for: try reviewedYouTube())
        XCTAssertEqual(source.effectiveMinimumAge(settings: [:]), 16)
        XCTAssertEqual(source.effectiveMinimumAge(settings: ["allowAgeRestricted": "false"]), 16)
        XCTAssertEqual(source.effectiveMinimumAge(settings: ["allowAgeRestricted": "true"]), 18)
        XCTAssertEqual(source.effectiveMinimumAge(settings: ["allowControversialRestricted": "true"]), 18)
    }

    func testRatedSettingsAreHeldSafeBelowTheirRating() throws {
        let source = CuratedSourceDatabase.shared.classification(for: try reviewedYouTube())
        let safe = ["allowAgeRestricted": "false", "allowControversialRestricted": "false"]
        // 16 or 17: YouTube runs, with the 18+ settings held safe.
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 16, upper: 17), supervision: .none,
                                        parentApproved: false).approval?.forcedSettings, safe)
        // An adult, or no age source and no parental controls: nothing held.
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 18, upper: nil), supervision: .none,
                                        parentApproved: false).approval?.forcedSettings, [:])
        XCTAssertEqual(PolicyRules.load(source, age: .unknown, supervision: .none,
                                        parentApproved: false).approval?.forcedSettings, [:])
        // A parent approved one setting: only the other is held.
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 16, upper: 17), supervision: .none,
                                        parentApproved: false, approvedSettings: ["allowAgeRestricted"])
            .approval?.forcedSettings, ["allowControversialRestricted": "false"])
    }

    func testChangingARatedSettingIsGatedLikeAnInstall() throws {
        let source = CuratedSourceDatabase.shared.classification(for: try reviewedYouTube())
        XCTAssertEqual(PolicyRules.settingChange(source, setting: "allowAgeRestricted", value: "true",
                                                 age: .range(lower: 16, upper: 17), supervision: .none),
                       .tooYoung(minimumAge: 18))
        XCTAssertNil(PolicyRules.settingChange(source, setting: "allowAgeRestricted", value: "false",
                                               age: .range(lower: 16, upper: 17), supervision: .none),
                     "turning a rated setting back to safe is always allowed")
        XCTAssertNil(PolicyRules.settingChange(source, setting: "showVerboseToasts", value: "true",
                                               age: .range(lower: 13, upper: 15), supervision: .none))
        XCTAssertNil(PolicyRules.settingChange(source, setting: "allowAgeRestricted", value: "true",
                                               age: .range(lower: 18, upper: nil), supervision: .none))
        XCTAssertEqual(PolicyRules.settingChange(source, setting: "allowAgeRestricted", value: "true",
                                                 age: .unknown, supervision: child),
                       .needsParentApproval(minimumAge: 18, unlisted: false))
        XCTAssertNil(PolicyRules.settingChange(source, setting: "allowAgeRestricted", value: "true",
                                               age: .unknown, supervision: child,
                                               approvedSettings: ["allowAgeRestricted"]))
    }

    @MainActor
    func testParentApprovalOfASettingUnlocksIt() async throws {
        let supervision = FixedSupervisionSource(.supervised(allowsInstallingApps: false, contentAgeLimit: nil))
        let approvals = ParentalApprovals(storage: .inMemory(), storageName: "approvals", profileChanges: nil)
        let policy = SourceAccessPolicy(
            ageSource: FixedAgeSource(.range(lowerBound: 16, upperBound: 17)), supervisionSource: supervision,
            profileAge: ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil),
            approvals: approvals
        )
        let youTube = try reviewedYouTube()
        let refused = await policy.approveSettingChange(youTube, setting: "allowAgeRestricted", value: "true")
        let denial = try XCTUnwrap(refused)
        let request = await policy.askParent(pluginID: youTubeID, name: "YouTube", setting: "allowAgeRestricted",
                                             settingName: "Allow Age Restricted", denial: denial)
        guard case .sent(let id) = request else { return XCTFail("the question should be sent") }
        await approvals.resolve(.init(requestID: id, approved: true))
        let allowed = await policy.approveSettingChange(youTube, setting: "allowAgeRestricted", value: "true")
        XCTAssertNil(allowed)
        let load = await policy.approveLoad(youTube)
        XCTAssertNil(load.approval?.forcedSettings["allowAgeRestricted"])
    }

    /// Hummingbird's forks are pinned to Hummingbird's own signing key,
    /// never the official plugins' ids or key.
    func testForksHaveTheirOwnIdentityAndKey() throws {
        let entries = CuratedSourceDatabase.shared.entries
        let forks = entries.filter { $0.name.hasSuffix("(Hummingbird)") }
        XCTAssertEqual(Set(forks.map(\.name)), ["Youtube (Hummingbird)", "Patreon (Hummingbird)"])
        let pem = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hummingbird-plugin-signing/plugin-signing-key.pub.pem"), encoding: .utf8)
        let key = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let official = entries.filter { !$0.name.hasSuffix("(Hummingbird)") }
        for fork in forks {
            XCTAssertEqual(fork.publicKey, key, fork.name)
            XCTAssertFalse(official.contains { $0.pluginID == fork.pluginID }, fork.name)
        }
        XCTAssertFalse(official.contains { $0.publicKey == key })
    }

    func testPatreonForkRatesItsNSFWSettings() throws {
        let fork = try XCTUnwrap(CuratedSourceDatabase.shared.entry(for: "bf1ab295-96fa-445d-bb78-215116ee472e"))
        let source = fork.classification
        XCTAssertEqual(source.effectiveMinimumAge(settings: [:]), 16)
        XCTAssertEqual(source.effectiveMinimumAge(settings: ["includeNsfwResults": "true"]), 18)
        XCTAssertEqual(source.effectiveMinimumAge(settings: ["showNsfwContent": "true"]), 18)
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 16, upper: 17), supervision: .none,
                                        parentApproved: false).approval?.forcedSettings,
                       ["includeNsfwResults": "false", "showNsfwContent": "false"])
    }

    func testImpersonationIsNamed() throws {
        var lookalike = try reviewedYouTube()
        XCTAssertNil(CuratedSourceDatabase.shared.reviewedName(ofLookalike: lookalike))
        lookalike.scriptPublicKey = "OTHER"
        XCTAssertEqual(CuratedSourceDatabase.shared.reviewedName(ofLookalike: lookalike), "Youtube")
    }

    @MainActor
    func testDiscoveryHidesSourcesAboveAKnownAge() async {
        let policy = makeTestPolicy(age: .range(lowerBound: 13, upperBound: 15))
        let entries = CuratedSourceDatabase.shared.entries
        let visibility = await policy.visibility(ofReviewed: entries)
        for entry in entries {
            let rating = entry.classification.minimumAge
            XCTAssertEqual(visibility[entry.pluginID], rating <= 13 ? .available : .hidden, entry.name)
        }
    }

    @MainActor
    func testDiscoveryLocksUnderParentalControls() async {
        let policy = makeTestPolicy(age: .unavailable,
                                    supervision: .supervised(allowsInstallingApps: false, contentAgeLimit: nil))
        let entries = CuratedSourceDatabase.shared.entries
        let visibility = await policy.visibility(ofReviewed: entries)
        for entry in entries where entry.classification.minimumAge > 0 {
            XCTAssertEqual(visibility[entry.pluginID],
                           .locked(.needsParentApproval(minimumAge: entry.classification.minimumAge, unlisted: false)),
                           entry.name)
        }
    }

    // MARK: signed updates

    private func signedList(version: Int, key: Curve25519.Signing.PrivateKey, format: Int = 1) throws -> (Data, Data) {
        let list = CuratedSourceList(format: format, version: version, generatedAt: "2026-11-17", entries: [
            CuratedSourceEntry(pluginID: "new", name: "New", publicKey: "KEY", category: .education, minimumAge: 0),
        ])
        let body = try JSONEncoder().encode(list)
        return (body, try key.signature(for: body))
    }

    func testSignedUpdateReplacesTheListOnlyWhenNewerAndGenuine() throws {
        let database = CuratedSourceDatabase(list: CuratedSourceList(format: 1, version: 5, generatedAt: "", entries: []))
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()

        let (forgedBody, forgedSignature) = try signedList(version: 9, key: other)
        XCTAssertThrowsError(try database.applyUpdate(body: forgedBody, signature: forgedSignature, publicKey: key.publicKey))
        let (oldBody, oldSignature) = try signedList(version: 5, key: key)
        XCTAssertThrowsError(try database.applyUpdate(body: oldBody, signature: oldSignature, publicKey: key.publicKey))
        let (futureBody, futureSignature) = try signedList(version: 9, key: key, format: 2)
        XCTAssertThrowsError(try database.applyUpdate(body: futureBody, signature: futureSignature, publicKey: key.publicKey))
        XCTAssertEqual(database.list.version, 5)

        let (body, signature) = try signedList(version: 6, key: key)
        var tampered = body
        tampered.append(contentsOf: Array(" ".utf8))
        XCTAssertThrowsError(try database.applyUpdate(body: tampered, signature: signature, publicKey: key.publicKey))
        try database.applyUpdate(body: body, signature: signature, publicKey: key.publicKey)
        XCTAssertEqual(database.list.version, 6)
        XCTAssertNotNil(database.entry(for: "new"))
    }

    func testAcceptedUpdateIsReverifiedAtLaunch() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let storage = Storage.inMemory()
        let (body, signature) = try signedList(version: 7, key: key)
        storage.save(CuratedSourceUpdater.Stored(body: body, signature: signature), name: "curated_sources_update")
        await storage.flush()
        let updater = CuratedSourceUpdater(listURL: URL(string: "https://example.com/list.json")!,
                                           publicKey: key.publicKey, storage: storage)
        let database = CuratedSourceDatabase(list: CuratedSourceList(format: 1, version: 1, generatedAt: "", entries: []))
        updater.restore(into: database)
        XCTAssertEqual(database.list.version, 7)

        let wrongKey = CuratedSourceUpdater(listURL: updater.listURL, publicKey: Curve25519.Signing.PrivateKey().publicKey,
                                            storage: storage)
        let untouched = CuratedSourceDatabase(list: CuratedSourceList(format: 1, version: 1, generatedAt: "", entries: []))
        wrongKey.restore(into: untouched)
        XCTAssertEqual(untouched.list.version, 1)
    }

    // MARK: install, without parental controls

    func testInstallMatrixWithoutParentalControls() {
        for (name, age) in ages {
            for minimumAge in [0, 13, 16, 18] {
                let result = PolicyRules.install(curated(minimumAge), age: age, supervision: .none, parentApproved: false)
                let expected: PolicyDenial?
                switch age.isAtLeast(minimumAge) {
                case true?: expected = nil
                case false?: expected = .tooYoung(minimumAge: minimumAge)
                case nil: expected = minimumAge == 0 ? nil : .ageNotConfirmed(minimumAge: minimumAge)
                }
                XCTAssertEqual(result.denial, expected, "\(name), rated \(minimumAge)")
            }
            let unlisted = PolicyRules.install(.unlisted("u"), age: age, supervision: .none, parentApproved: false)
            switch name {
            case "adult", "unknown": XCTAssertNil(unlisted.denial, name)
            case "declined": XCTAssertEqual(unlisted.denial, .ageNotConfirmed(minimumAge: 18))
            default: XCTAssertEqual(unlisted.denial, .tooYoung(minimumAge: 18), name)
            }
        }
    }

    func testNoPlatformAgeIsTreatedAsAdult() {
        XCTAssertEqual(AgeEvidence.unknown.isAtLeast(18), true)
        XCTAssertNil(PolicyRules.install(curated(18), age: .unknown, supervision: .none, parentApproved: false).denial)
        XCTAssertEqual(PolicyRules.load(curated(18, restricted: ["a": "false"]), age: .unknown, supervision: .none, parentApproved: false)
            .approval?.forcedSettings, [:])
    }

    // MARK: load and restricted modes

    func testLoadForcesRestrictedModesUnlessAdult() {
        let source = curated(13, restricted: ["allowAgeRestricted": "false"])
        let forced = ["allowAgeRestricted": "false"]
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 13, upper: 15), supervision: .none, parentApproved: false).approval?.forcedSettings, forced)
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 16, upper: 17), supervision: .none, parentApproved: false).approval?.forcedSettings, forced)
        XCTAssertEqual(PolicyRules.load(source, age: .declined, supervision: .none, parentApproved: false).approval?.forcedSettings, forced)
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 18, upper: nil), supervision: .none, parentApproved: false).approval?.forcedSettings, [:])
        XCTAssertEqual(PolicyRules.load(source, age: .range(lower: 0, upper: 12), supervision: .none, parentApproved: false).denial, .tooYoung(minimumAge: 13))
    }

    func testDeclinedLoadStandsOnTheInstallCheck() {
        XCTAssertNotNil(PolicyRules.load(curated(18), age: .declined, supervision: .none, parentApproved: false).approval)
        XCTAssertEqual(PolicyRules.load(curated(18), age: .range(lower: 16, upper: 17), supervision: .none, parentApproved: false).denial,
                       .tooYoung(minimumAge: 18), "an age that is now known to be too young stops a load")
    }

    // MARK: the system's parental controls

    private let child = Supervision.supervised(allowsInstallingApps: false, contentAgeLimit: nil)

    func testSupervisionWithoutAnAgeIsNotAdult() {
        XCTAssertEqual(PolicyRules.install(curated(18), age: .unknown, supervision: child, parentApproved: false).denial,
                       .needsParentApproval(minimumAge: 18, unlisted: false))
        XCTAssertNil(PolicyRules.install(curated(0), age: .unknown, supervision: child, parentApproved: false).denial)
        XCTAssertEqual(PolicyRules.load(curated(0, restricted: ["r": "off"]), age: .unknown, supervision: child,
                                        parentApproved: false).approval?.forcedSettings, ["r": "off"],
                       "restricted modes stay on under parental controls")
    }

    func testParentApprovalUnlocksAnySource() {
        for (name, age) in ages {
            XCTAssertNil(PolicyRules.install(.unlisted("u"), age: age, supervision: child, parentApproved: true).denial, name)
            XCTAssertNil(PolicyRules.load(curated(18), age: age, supervision: child, parentApproved: true).denial, name)
        }
    }

    func testArbitraryPluginNeeds18OrAParent() {
        XCTAssertNil(PolicyRules.install(.unlisted("u"), age: .range(lower: 18, upper: nil), supervision: .none,
                                         parentApproved: false).denial)
        XCTAssertNil(PolicyRules.install(.unlisted("u"), age: .unknown, supervision: .none, parentApproved: false).denial,
                     "no age source and no parental controls: adult")
        XCTAssertEqual(PolicyRules.install(.unlisted("u"), age: .range(lower: 16, upper: 17), supervision: .none,
                                           parentApproved: false).denial, .tooYoung(minimumAge: 18))
        XCTAssertEqual(PolicyRules.install(.unlisted("u"), age: .range(lower: 16, upper: 17), supervision: child,
                                           parentApproved: false).denial,
                       .needsParentApproval(minimumAge: 18, unlisted: true))
    }

    func testMalcontentStyleSupervision() {
        // A parent who lets the child install software still filters content.
        let installs = Supervision.supervised(allowsInstallingApps: true, contentAgeLimit: 0)
        XCTAssertEqual(PolicyRules.install(curated(13), age: .range(lower: 18, upper: nil), supervision: installs,
                                           parentApproved: false).denial,
                       .needsParentApproval(minimumAge: 13, unlisted: false))
        let noContentFilter = Supervision.supervised(allowsInstallingApps: true, contentAgeLimit: nil)
        XCTAssertNil(PolicyRules.install(.unlisted("u"), age: .range(lower: 18, upper: nil), supervision: noContentFilter,
                                         parentApproved: false).denial)
    }

    func testSupervisionStatusMapping() {
        XCTAssertEqual(Supervision(.unavailable), .none, "no system parental controls reported: none")
        XCTAssertEqual(Supervision(.notSupervised), .none)
        XCTAssertEqual(Supervision(.supervised(allowsInstallingApps: false, contentAgeLimit: 0)),
                       .supervised(allowsInstallingApps: false, contentAgeLimit: 0))
    }

    func testCatalogVisibility() {
        XCTAssertEqual(PolicyRules.visibility(curated(18), age: .range(lower: 13, upper: 15), supervision: .none,
                                              parentApproved: false), .hidden)
        XCTAssertEqual(PolicyRules.visibility(curated(18), age: .declined, supervision: .none, parentApproved: false),
                       .locked(.ageNotConfirmed(minimumAge: 18)))
        XCTAssertEqual(PolicyRules.visibility(curated(13), age: .range(lower: 13, upper: 15), supervision: .none,
                                              parentApproved: false), .available)
        XCTAssertEqual(PolicyRules.visibility(curated(16), age: .unknown, supervision: child, parentApproved: false),
                       .locked(.needsParentApproval(minimumAge: 16, unlisted: false)))
    }

    @MainActor
    func testAskingAParentRecordsAndResolvesTheRequest() async throws {
        let supervision = FixedSupervisionSource(.supervised(allowsInstallingApps: false, contentAgeLimit: nil))
        let approvals = ParentalApprovals(storage: .inMemory(), storageName: "approvals", profileChanges: nil)
        let policy = SourceAccessPolicy(
            ageSource: FixedAgeSource(.range(lowerBound: 13, upperBound: 15)), supervisionSource: supervision,
            profileAge: ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil),
            approvals: approvals
        )
        let youTube = try reviewedYouTube()
        let before = await policy.approveInstall(youTube)
        let denial = try XCTUnwrap(before.denial)
        XCTAssertTrue(denial.parentCanApprove)

        var installed: [String] = []
        approvals.onApproved.append { installed.append($0.pluginID) }
        let request = await policy.askParent(pluginID: youTubeID, name: "YouTube",
                                             sourceURL: "https://example.com/config.json", denial: denial)
        guard case .sent(let id) = request else { return XCTFail("the question should be sent") }
        XCTAssertEqual(approvals.pending.map(\.pluginID), [youTubeID])

        await approvals.resolve(.init(requestID: UUID(), approved: true))
        XCTAssertTrue(installed.isEmpty, "an answer to another question changes nothing")
        await approvals.resolve(.init(requestID: id, approved: true))
        XCTAssertEqual(installed, [youTubeID])
        XCTAssertTrue(approvals.pending.isEmpty)
        let after = await policy.approveInstall(youTube)
        XCTAssertNotNil(after.approval)

        await approvals.withdraw(youTubeID)
        let withdrawn = await policy.approveInstall(youTube)
        XCTAssertNotNil(withdrawn.denial)
    }

    @MainActor
    func testADeclinedRequestApprovesNothing() async throws {
        let approvals = ParentalApprovals(storage: .inMemory(), storageName: "approvals", profileChanges: nil)
        let id = UUID()
        await approvals.recordRequest(id: id, pluginID: "x", name: "X", sourceURL: "https://example.com/x.json")
        await approvals.resolve(.init(requestID: id, approved: false))
        let approved = await approvals.current()
        XCTAssertTrue(approved.isEmpty)
        XCTAssertTrue(approvals.pending.isEmpty)
    }

    @MainActor
    func testEveryDecisionAsksForTheAgeAgain() async throws {
        let ageSource = FixedAgeSource(.range(lowerBound: 13, upperBound: 15))
        let profileAge = ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil)
        let policy = SourceAccessPolicy(
            ageSource: ageSource, supervisionSource: FixedSupervisionSource(.notSupervised), profileAge: profileAge,
            approvals: ParentalApprovals(storage: .inMemory(), storageName: "approvals", profileChanges: nil)
        )
        let youTube = try reviewedYouTube()
        let minorLoad = await policy.approveLoad(youTube)
        XCTAssertEqual(minorLoad.denial, .tooYoung(minimumAge: 16))
        XCTAssertEqual(ageSource.requests, 1)

        // The platform now reports an adult: the next decision sees it.
        ageSource.answer = .range(lowerBound: 18, upperBound: nil)
        let adultLoad = await policy.approveLoad(youTube)
        XCTAssertNotNil(adultLoad.approval)
        XCTAssertEqual(ageSource.requests, 2)

        // A later, lower report cannot lower the profile's bound.
        ageSource.answer = .range(lowerBound: 13, upperBound: 15)
        let laterLoad = await policy.approveLoad(youTube)
        XCTAssertNotNil(laterLoad.approval)
        XCTAssertEqual(ageSource.requests, 3)
    }

    @MainActor
    func testDeclinedAndUnavailableNeverWriteTheProfile() async throws {
        let ageSource = FixedAgeSource(.declined)
        let profileAge = ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil)
        let policy = SourceAccessPolicy(
            ageSource: ageSource, supervisionSource: FixedSupervisionSource(.notSupervised), profileAge: profileAge,
            approvals: ParentalApprovals(storage: .inMemory(), storageName: "approvals", profileChanges: nil)
        )
        let youTube = try reviewedYouTube()
        let declined = await policy.approveInstall(youTube)
        XCTAssertEqual(declined.denial, .ageNotConfirmed(minimumAge: 16))
        ageSource.answer = .unavailable
        let unknown = await policy.approveInstall(youTube)
        XCTAssertNotNil(unknown.approval, "no bound and no platform age: adult")
        let stored = await profileAge.current()
        XCTAssertNil(stored)

        // Once a platform has shared a range, other devices use the bound.
        ageSource.answer = .range(lowerBound: 13, upperBound: 15)
        _ = await policy.approveLoad(youTube)
        ageSource.answer = .unavailable
        let boundOnly = await policy.approveInstall(youTube)
        XCTAssertEqual(boundOnly.denial, .ageNotConfirmed(minimumAge: 16),
                       "a profile known to be at least 13 is not treated as adult")
    }

    func testEffectiveAgeCombinesReportAndBound() {
        XCTAssertEqual(PolicyRules.effectiveAge(device: .unknown, profileMinimumAge: nil), .unknown)
        XCTAssertEqual(PolicyRules.effectiveAge(device: .declined, profileMinimumAge: nil), .declined)
        XCTAssertEqual(PolicyRules.effectiveAge(device: .unknown, profileMinimumAge: 16), .range(lower: 16, upper: nil))
        XCTAssertEqual(PolicyRules.effectiveAge(device: .range(lower: 13, upper: 15), profileMinimumAge: 16),
                       .range(lower: 16, upper: nil))
        XCTAssertEqual(PolicyRules.effectiveAge(device: .range(lower: 16, upper: 17), profileMinimumAge: 13),
                       .range(lower: 16, upper: 17))
    }

    // MARK: the profile's birthday bound

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)!.addingTimeInterval(12 * 3600)
    }

    func testBoundAdvancesOnExactlyItsAnniversary() {
        let bound = SyncedAgeRange(lowerBound: 13, measuredAt: date("2023-03-01"), now: date("2026-01-01"))
        XCTAssertEqual(bound.latestPossibleBirthday, .init(year: 2010, month: 3, day: 1))
        XCTAssertEqual(bound.minimumAge(on: date("2026-02-28")), 15)
        XCTAssertEqual(bound.minimumAge(on: date("2026-03-01")), 16)
        XCTAssertEqual(bound.minimumAge(on: date("2028-03-01")), 18)
    }

    func testLeapDayBoundsNeverClaimTooMuch() {
        // Measured on 29 February: 29 February 2011 doesn't exist, so the bound
        // is the 28th, which proves no more than the report did.
        let fromLeapDay = SyncedAgeRange(lowerBound: 13, measuredAt: date("2024-02-29"), now: date("2025-01-01"))
        XCTAssertEqual(fromLeapDay.latestPossibleBirthday, .init(year: 2011, month: 2, day: 28))
        XCTAssertEqual(fromLeapDay.minimumAge(on: date("2024-02-29")), 13)

        // A bound on 29 February has its anniversary on 1 March in other years.
        let leapBound = SyncedAgeRange(lowerBound: 16, measuredAt: date("2028-02-29"), now: date("2029-01-01"))
        XCTAssertEqual(leapBound.latestPossibleBirthday, .init(year: 2012, month: 2, day: 29))
        XCTAssertEqual(leapBound.minimumAge(on: date("2029-02-28")), 16)
        XCTAssertEqual(leapBound.minimumAge(on: date("2030-02-28")), 17)
        XCTAssertEqual(leapBound.minimumAge(on: date("2030-03-01")), 18)
    }

    func testFutureDatedMeasurementIsClampedToNow() {
        let skewed = SyncedAgeRange(lowerBound: 13, measuredAt: date("2030-06-01"), now: date("2026-06-01"))
        XCTAssertEqual(skewed.measuredAt, date("2026-06-01"))
        XCTAssertEqual(skewed.minimumAge(on: date("2026-06-01")), 13)
    }

    func testBoundMergeIsCommutativeAndConverges() {
        let records = [
            SyncedAgeRange(lowerBound: 13, measuredAt: date("2023-06-01"), now: date("2026-01-01")),
            SyncedAgeRange(lowerBound: 13, measuredAt: date("2023-01-01"), now: date("2026-01-01")),
            SyncedAgeRange(lowerBound: 16, measuredAt: date("2025-09-01"), now: date("2026-01-01")),
            SyncedAgeRange(lowerBound: 0, measuredAt: date("2025-12-01"), now: date("2026-01-01")),
        ]
        let expected = records.reduce(nil) { ProfileAgeRange.merged($0, $1) }
        for order in [records, records.reversed(), [records[2], records[0], records[3], records[1]]] {
            XCTAssertEqual(order.reduce(nil) { ProfileAgeRange.merged($0, $1) }, expected)
        }
        for a in records { for b in records {
            XCTAssertEqual(ProfileAgeRange.merged(a, b), ProfileAgeRange.merged(b, a))
        } }
        XCTAssertEqual(expected?.latestPossibleBirthday, .init(year: 2009, month: 9, day: 1))
    }

    @MainActor
    func testRemoteBoundOnlyTightens() async {
        let profileAge = ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil)
        await profileAge.record(lowerBound: 16, now: date("2026-01-01"))
        await profileAge.applyRemote(SyncedAgeRange(lowerBound: 13, measuredAt: date("2026-01-01")), now: date("2026-01-02"))
        XCTAssertEqual(profileAge.record?.minimumAge(on: date("2026-01-02")), 16)
        await profileAge.applyRemote(SyncedAgeRange(lowerBound: 18, measuredAt: date("2026-01-01")), now: date("2026-01-02"))
        XCTAssertEqual(profileAge.record?.minimumAge(on: date("2026-01-02")), 18)
        await profileAge.record(lowerBound: 13, now: date("2026-02-01"))
        XCTAssertEqual(profileAge.record?.minimumAge(on: date("2026-02-01")), 18)
    }

    @MainActor
    func testPluginManagerRefusesToStartADeniedPlugin() async throws {
        let youTube = try reviewedYouTube()
        let stores = makeTestStores()
        let manager = PluginManager(
            installed: [InstalledPlugin(config: youTube, script: "source.enable = function() {};")],
            storage: stores.storage, credentialStore: stores.credentialStore,
            policy: makeTestPolicy(age: .range(lowerBound: 0, upperBound: 12))
        )
        let runtime = await manager.runtime(for: youTubeID)
        XCTAssertNil(runtime)
        XCTAssertEqual(manager.loadDenials[youTubeID], .tooYoung(minimumAge: 16))
    }

    func testRuntimeAppliesForcedSettings() throws {
        let youTube = try reviewedYouTube()
        let source = CuratedSourceDatabase.shared.classification(for: youTube)
        // Declined: an installed source still loads, in its restricted mode.
        guard case .success(let approval) = PolicyRules.load(source, age: .declined, supervision: .none,
                                                             parentApproved: false) else {
            return XCTFail("an installed source loads when the age is declined")
        }
        XCTAssertEqual(approval.forcedSettings, source.restrictedModeSettings)
        XCTAssertEqual(approval.forcedSettings["allowAgeRestricted"], "false")
    }

    // MARK: passcode storage

    // MARK: lowering the profile's age

    @MainActor
    func testAnyoneCanLowerTheAgeAndItSyncs() async {
        let phone = ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil)
        let laptop = ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil)
        await phone.record(lowerBound: 18, now: date("2026-01-01"))
        await laptop.applyRemote(phone.record!, now: date("2026-01-01"))

        // A mistaken adult report is corrected down to 13 on the laptop.
        await laptop.lower(toMinimumAge: 13, now: date("2026-02-01"))
        XCTAssertEqual(laptop.record?.minimumAge(on: date("2026-02-01")), 13)

        // The correction outranks the tighter, older bound on the phone.
        await phone.applyRemote(laptop.record!, now: date("2026-02-01"))
        XCTAssertEqual(phone.record?.minimumAge(on: date("2026-02-01")), 13)
        // The phone's stale record no longer wins back on the laptop.
        await laptop.applyRemote(SyncedAgeRange(lowerBound: 18, measuredAt: date("2026-01-01")), now: date("2026-02-02"))
        XCTAssertEqual(laptop.record?.minimumAge(on: date("2026-02-02")), 13)

        // A fresh platform report can still raise it again.
        await laptop.record(lowerBound: 16, now: date("2026-03-01"))
        XCTAssertEqual(laptop.record?.minimumAge(on: date("2026-03-01")), 16)
    }

    func testCorrectionMergeConverges() {
        let report = SyncedAgeRange(lowerBound: 18, measuredAt: date("2026-01-01"), now: date("2026-03-01"))
        let correction = SyncedAgeRange(lowerBound: 13, measuredAt: date("2026-02-01"), now: date("2026-03-01"),
                                        source: "correction", correctedAt: date("2026-02-01"))
        let laterReport = SyncedAgeRange(lowerBound: 16, measuredAt: date("2026-02-15"), now: date("2026-03-01"),
                                         correctedAt: date("2026-02-01"))
        let records = [report, correction, laterReport]
        let expected = records.reduce(nil) { ProfileAgeRange.merged($0, $1) }
        for order in [records, records.reversed(), [correction, report, laterReport]] {
            XCTAssertEqual(order.reduce(nil) { ProfileAgeRange.merged($0, $1) }, expected)
        }
        XCTAssertEqual(expected, laterReport)
    }

    @MainActor
    func testLoweringNeedsAHigherCurrentAge() async {
        let profileAge = ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil)
        await profileAge.lower(toMinimumAge: 13, now: date("2026-01-01"))
        XCTAssertNil(profileAge.record, "nothing to lower")
        await profileAge.record(lowerBound: 13, now: date("2026-01-01"))
        await profileAge.lower(toMinimumAge: 16, now: date("2026-01-01"))
        XCTAssertEqual(profileAge.record?.minimumAge(on: date("2026-01-01")), 13, "lowering cannot raise")
    }

    func testDeclinedGivesWayToAProfileBound() {
        XCTAssertEqual(PolicyRules.effectiveAge(device: .declined, profileMinimumAge: 18), .range(lower: 18, upper: nil))
        XCTAssertNil(PolicyRules.install(curated(18), age: PolicyRules.effectiveAge(device: .declined, profileMinimumAge: 18),
                                         supervision: .none, parentApproved: false).denial)
    }

    // MARK: login confinement

    func testLoginScopeKeepsToTheSourcesDomains() throws {
        var youTube = try config(youTubeID)
        youTube.allowUrls = ["youtube.com", "m.youtube.com", "everywhere"]
        youTube.authentication = try JSONDecoder().decode(PluginAuthConfig.self, from: Data(#"""
            {"loginUrl":"https://accounts.google.com/ServiceLogin?service=youtube",
             "completionUrl":"https://m.youtube.com/youtubei/v1/guide?*"}
            """#.utf8))
        let scope = LoginNavigationScope.login(for: youTube)
        for allowed in ["https://accounts.google.com/v3/signin", "https://myaccount.google.com/",
                        "https://www.youtube.com/signin", "https://accounts.youtube.com/CheckCookie", "about:blank"] {
            XCTAssertTrue(scope.allows(URL(string: allowed)!), allowed)
        }
        for blocked in ["https://example.com/", "https://www.wikipedia.org/", "https://google.com.evil.example/",
                        "javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd"] {
            XCTAssertFalse(scope.allows(URL(string: blocked)!), blocked)
        }
    }

    func testSiteWideningAvoidsPublicSuffixes() {
        XCTAssertEqual(LoginNavigationScope.site(of: URL(string: "https://accounts.google.com/")!), "google.com")
        XCTAssertEqual(LoginNavigationScope.site(of: URL(string: "https://login.bbc.co.uk/")!), "bbc.co.uk")
        XCTAssertEqual(LoginNavigationScope.site(of: URL(string: "https://example.org/")!), "example.org")
        XCTAssertEqual(LoginNavigationScope.site(of: URL(string: "https://10.0.0.1/")!), "10.0.0.1")
    }

    @MainActor
    func testOAuthTabStaysOnTheAuthorizationServer() {
        let authorization = OAuthTabAuthorization(
            authorizationURL: URL(string: "https://auth.pds.example.net/oauth/authorize")!,
            callback: OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI)!
        )
        XCTAssertTrue(authorization.shouldLoad(URL(string: "https://pds.example.net/account")!))
        XCTAssertFalse(authorization.shouldLoad(URL(string: "https://news.example.com/")!))
        XCTAssertTrue(authorization.shouldLoad(URL(string: "https://captcha.example.com/")!, isMainFrame: false))
    }
}

private extension Result where Failure == PolicyDenial {
    var denial: PolicyDenial? { if case .failure(let d) = self { d } else { nil } }
    var approval: Success? { try? get() }
}
