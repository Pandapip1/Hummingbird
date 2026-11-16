import Foundation
import XCTest
@testable import ATProtoKit
@testable import HummingbirdKit

@MainActor
final class ProfileScopeGatingTests: XCTestCase {
    private func credential(scope: String) throws -> ATProtoOAuthCredential {
        let session = ATProtoOAuthSession(
            account: try XCTUnwrap(DID(rawValue: "did:plc:pandapip1")), handle: "pandapip1.bsky.social",
            pds: try XCTUnwrap(URL(string: "https://pds.example")),
            authorizationServer: try XCTUnwrap(URL(string: "https://bsky.social")),
            accessToken: SecureBytes(copyingUTF8: "a"), refreshToken: nil,
            scope: scope, tokenType: "DPoP", expiresAt: nil
        )
        return ATProtoOAuthCredential(session: session, dpopPrivateKey: SecureBytes(copyingUTF8: "key"))
    }

    func testOnlyAtprotoIsRequired() {
        XCTAssertEqual(ProfileAccountService.configuration.requiredScopes, ["atproto"])
        XCTAssertTrue(ProfileAccountService.configuration.scopes.contains {
            ProfileAccountService.grantsProfileSpace([$0])
        }, "the profile-space permission is still requested")
        XCTAssertEqual(ProfileAccountService.profileSpaceType, HummingbirdProfileSchema.spaceType.rawValue)
    }

    func testGrantRecognizesTheProfileSpacePermission() {
        XCTAssertTrue(ProfileAccountService.grantsProfileSpace([
            "atproto", "space:com.eightybps.hummingbird.profile?authority=self&skey=self&manage=create",
        ]))
        XCTAssertTrue(ProfileAccountService.grantsProfileSpace(["atproto", "space:com.eightybps.hummingbird.profile"]))
        XCTAssertFalse(ProfileAccountService.grantsProfileSpace(["atproto"]))
        XCTAssertFalse(ProfileAccountService.grantsProfileSpace(["atproto", "space:com.eightybps.hummingbird.profiles"]))
    }

    func testAReducedGrantSignsInWithProfileSyncOffAndANotice() throws {
        let account = makeTestAppModel().profileAccount
        account.install(try credential(scope: "atproto"))
        XCTAssertEqual(account.account?.rawValue, "did:plc:pandapip1")
        XCTAssertNil(account.errorMessage, "a reduced grant is not an error")
        XCTAssertEqual(account.profileSyncNotice, ProfileAccountService.profileSpaceNotGrantedNotice)
        XCTAssertEqual(account.profileSyncNotice,
                       "Your server didn’t grant Hummingbird’s profile-space permission, so profile sync is off.")
        XCTAssertFalse(account.syncService?.isAccountConnected ?? true, "profile sync must not use the account")
    }

    func testAFullGrantConnectsProfileSync() throws {
        let account = makeTestAppModel().profileAccount
        account.install(try credential(
            scope: "atproto space:com.eightybps.hummingbird.profile?authority=self&skey=self&manage=create"
        ))
        XCTAssertNil(account.profileSyncNotice)
        XCTAssertNil(account.errorMessage)
        XCTAssertTrue(account.syncService?.isAccountConnected ?? false)
    }
}
