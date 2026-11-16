import Foundation
import XCTest
import CredentialStorage
@testable import ATProtoKit
@testable import HummingbirdKit

/// Prepares against scripted server metadata and completes with a grant of
/// only the scopes it was asked for, without a network.
private actor ScriptedFlow: OAuthAuthorizationFlow {
    private let scopesSupported: [String]?
    private(set) var begun = 0
    private(set) var requestedScopes: [[String]] = []

    init(scopesSupported: [String]?) { self.scopesSupported = scopesSupported }

    func prepare(identifier: String) async throws -> ATProtoPreparedAuthorization {
        let metadata = OAuthAuthorizationServerMetadata(
            issuer: URL(string: "https://bsky.social")!,
            authorizationEndpoint: URL(string: "https://bsky.social/oauth/authorize")!,
            tokenEndpoint: URL(string: "https://bsky.social/oauth/token")!,
            pushedAuthorizationRequestEndpoint: URL(string: "https://bsky.social/oauth/par")!,
            scopesSupported: scopesSupported
        )
        let identity = ResolvedIdentity(did: DID(rawValue: "did:plc:pandapip1")!, handle: "pandapip1.bsky.social",
                                        pds: URL(string: "https://pds.example")!)
        let configuration = ProfileAccountService.configuration
        return try ATProtoPreparedAuthorization(identity: identity, metadata: metadata,
                                                scopes: configuration.scopes,
                                                requiredScopes: configuration.requiredScopes)
    }

    func begin(_ prepared: ATProtoPreparedAuthorization) async throws -> OAuthAuthorizationRequest {
        begun += 1
        requestedScopes.append(prepared.requestedScopes)
        return OAuthAuthorizationRequest(
            authorizationURL: URL(string: "https://bsky.social/oauth/authorize?request_uri=req-\(begun)")!,
            callback: .customScheme("com.eightybps.hummingbird"), state: "s", verifier: "v",
            issuer: URL(string: "https://bsky.social")!, pds: URL(string: "https://pds.example")!,
            account: DID(rawValue: "did:plc:pandapip1")!, loginHint: "pandapip1.bsky.social",
            dpopSigner: DPoPSigner(), dpopNonce: nil
        )
    }

    func complete(_ request: OAuthAuthorizationRequest, callbackURL: URL) async throws -> ATProtoOAuthCredential {
        let session = ATProtoOAuthSession(
            account: request.account, handle: request.loginHint, pds: request.pds,
            authorizationServer: request.issuer, accessToken: SecureBytes(copyingUTF8: "a"), refreshToken: nil,
            scope: requestedScopes.last?.joined(separator: " ") ?? "atproto", tokenType: "DPoP", expiresAt: nil
        )
        return ATProtoOAuthCredential(session: session, dpopPrivateKey: await request.dpopSigner.exportForStorage())
    }
}

@MainActor
private final class CountingPresenter: ATProtoOAuthPresenter {
    var opened: [URL] = []
    func authorize(_ authorizationURL: URL, callback: OAuthCallbackMatcher) async throws -> URL {
        opened.append(authorizationURL)
        return URL(string: "com.eightybps.hummingbird:/oauth/callback?code=c")!
    }
}

@MainActor
final class SignInScopeConfirmationTests: XCTestCase {
    private let bluesky = ["atproto", "transition:email", "transition:generic", "transition:chat.bsky"]
    private var model: AppModel!

    override func setUp() async throws {
        model = makeTestAppModel()
    }

    override func tearDown() async throws {
        model = nil
    }

    private func account(_ flow: ScriptedFlow, _ presenter: CountingPresenter) -> ProfileAccountService {
        ProfileAccountService(
            localProfileID: UUID(), stores: model.stores,
            changes: model.profileChanges, library: model.library, plugins: model.plugins,
            peerService: nil, oauthPresenter: presenter,
            authenticator: ATProtoOAuthAuthenticator(flow: flow, presenter: presenter)
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    func testUnsupportedProfileSpaceAsksAndCancelOpensNothing() async {
        let flow = ScriptedFlow(scopesSupported: bluesky)
        let presenter = CountingPresenter()
        let account = account(flow, presenter)
        let signIn = Task { await account.signIn(identifier: "pandapip1.bsky.social") }
        await waitUntil { account.signInConfirmation != nil }
        XCTAssertEqual(account.signInConfirmation, ProfileAccountService.profileSpaceUnsupportedPrompt)
        XCTAssertEqual(account.signInConfirmation,
                       "Your server doesn’t support Hummingbird’s profile-space permission yet, so profile sync "
                       + "will stay off; local network sync still works. Sign in anyway?")
        XCTAssertTrue(presenter.opened.isEmpty, "nothing opens before the answer")

        account.answerSignInConfirmation(false)
        await signIn.value
        XCTAssertNil(account.signInConfirmation)
        XCTAssertTrue(presenter.opened.isEmpty, "Cancel opens no sign-in tab")
        let begun = await flow.begun
        XCTAssertEqual(begun, 0, "Cancel pushes no authorization request")
        XCTAssertNil(account.account)
        XCTAssertNil(account.errorMessage, "cancelling is not an error")
    }

    func testSignInAnywayOpensWithoutTheUnsupportedScopeAndKeepsTheWarning() async {
        let flow = ScriptedFlow(scopesSupported: bluesky)
        let presenter = CountingPresenter()
        let account = account(flow, presenter)
        let signIn = Task { await account.signIn(identifier: "pandapip1.bsky.social") }
        await waitUntil { account.signInConfirmation != nil }
        account.answerSignInConfirmation(true)
        await signIn.value
        XCTAssertEqual(presenter.opened.count, 1)
        let requested = await flow.requestedScopes
        XCTAssertEqual(requested, [["atproto"]], "the consent screen only shows what can be granted")
        XCTAssertEqual(account.account?.rawValue, "did:plc:pandapip1")
        XCTAssertEqual(account.profileSyncNotice, ProfileAccountService.profileSpaceNotGrantedNotice)
        XCTAssertNil(account.errorMessage)
    }

    func testSupportedProfileSpaceOpensDirectly() async {
        let flow = ScriptedFlow(scopesSupported: bluesky + ["space"])
        let presenter = CountingPresenter()
        let account = account(flow, presenter)
        await account.signIn(identifier: "pandapip1.bsky.social")
        XCTAssertNil(account.signInConfirmation)
        XCTAssertEqual(presenter.opened.count, 1)
        let requested = await flow.requestedScopes
        XCTAssertEqual(requested, [ProfileAccountService.configuration.scopes])
        XCTAssertNil(account.profileSyncNotice)
    }

    func testServerWithoutScopesSupportedOpensDirectly() async {
        let flow = ScriptedFlow(scopesSupported: nil)
        let presenter = CountingPresenter()
        let account = account(flow, presenter)
        await account.signIn(identifier: "pandapip1.bsky.social")
        XCTAssertNil(account.signInConfirmation)
        XCTAssertEqual(presenter.opened.count, 1)
    }

    func testCancellingTheSignInTaskAnswersCancel() async {
        let flow = ScriptedFlow(scopesSupported: bluesky)
        let presenter = CountingPresenter()
        let account = account(flow, presenter)
        let signIn = Task { await account.signIn(identifier: "pandapip1.bsky.social") }
        await waitUntil { account.signInConfirmation != nil }
        signIn.cancel()
        await signIn.value
        XCTAssertNil(account.signInConfirmation)
        XCTAssertTrue(presenter.opened.isEmpty)
    }
}
