import ATProtoKit
import Foundation
import XCTest
@testable import HummingbirdKit

@MainActor
private final class RecordingHost: OAuthTabHost {
    var presented: [OAuthTabAuthorization] = []
    var dismissed: [OAuthTabAuthorization.ID] = []
    func presentOAuthAuthorization(_ authorization: OAuthTabAuthorization) { presented.append(authorization) }
    func dismissOAuthAuthorization(_ authorization: OAuthTabAuthorization) { dismissed.append(authorization.id) }
}

@MainActor
final class OAuthTabPresenterTests: XCTestCase {
    private let authorizationURL = URL(string: "https://pds.example.net/oauth/authorize?request_uri=urn:1")!
    private let redirect = URL(string: "com.eightybps.hummingbird:/oauth/callback?code=abc&state=xyz&iss=https://pds.example.net")!
    private var callback: OAuthCallbackMatcher {
        OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI)!
    }

    // MARK: Navigation interception

    func testOrdinaryNavigationsLoad() {
        let authorization = OAuthTabAuthorization(authorizationURL: authorizationURL, callback: callback)
        XCTAssertTrue(authorization.shouldLoad(authorizationURL))
        XCTAssertTrue(authorization.shouldLoad(URL(string: "https://pds.example.net/oauth/authorize/accept")!))
        XCTAssertTrue(authorization.shouldLoad(URL(string: "about:blank")!))
        XCTAssertFalse(authorization.isFinished)
    }

    func testRedirectIsCancelledAndCompletesTheAuthorization() async throws {
        let authorization = OAuthTabAuthorization(authorizationURL: authorizationURL, callback: callback)
        XCTAssertFalse(authorization.shouldLoad(redirect), "the redirect URI must not be loaded")
        XCTAssertTrue(authorization.isFinished)
        let delivered = try await authorization.callbackURL()
        XCTAssertEqual(delivered, redirect)
    }

    func testOnlyTheFirstOutcomeCounts() async throws {
        let authorization = OAuthTabAuthorization(authorizationURL: authorizationURL, callback: callback)
        XCTAssertFalse(authorization.shouldLoad(redirect))
        authorization.cancel()
        XCTAssertFalse(authorization.shouldLoad(URL(string: "com.eightybps.hummingbird:/oauth/callback?code=other")!))
        let delivered = try await authorization.callbackURL()
        XCTAssertEqual(delivered, redirect)
    }

    // MARK: Presenter

    func testPresenterReturnsTheInterceptedRedirect() async throws {
        let host = RecordingHost()
        let presenter = OAuthTabPresenter(host: host)
        let task = Task { try await presenter.authorize(authorizationURL, callback: callback) }
        await waitUntil { !host.presented.isEmpty }
        let authorization = try XCTUnwrap(host.presented.first)
        XCTAssertEqual(authorization.authorizationURL, authorizationURL)
        XCTAssertFalse(authorization.shouldLoad(redirect))
        let delivered = try await task.value
        XCTAssertEqual(delivered, redirect)
        XCTAssertEqual(host.dismissed, [authorization.id])
    }

    func testCancellingTheTaskCancelsTheAuthorization() async throws {
        let host = RecordingHost()
        let presenter = OAuthTabPresenter(host: host)
        let task = Task { try await presenter.authorize(authorizationURL, callback: callback) }
        await waitUntil { !host.presented.isEmpty }
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(host.dismissed, host.presented.map(\.id))
    }

    func testPresenterWithoutAHostFails() async {
        let presenter = OAuthTabPresenter()
        do {
            _ = try await presenter.authorize(authorizationURL, callback: callback)
            XCTFail("Expected failure")
        } catch OAuthError.authorizationFailed {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: Browser tabs

    func testSignInOpensATabAndReturnsToTheStartingTab() async throws {
        let model = makeTestAppModel()
        let startingTab = model.activeTabID
        let presenter = OAuthTabPresenter(host: model)
        let task = Task { try await presenter.authorize(authorizationURL, callback: callback) }
        await waitUntil { !model.oauthAuthorizations.isEmpty }
        let authorization = try XCTUnwrap(model.oauthAuthorizations.values.first)
        XCTAssertEqual(model.activeTab.current, .oauthAuthorization(authorization.id))
        XCTAssertEqual(model.contentTabs.count, 2)

        XCTAssertFalse(authorization.shouldLoad(redirect))
        let delivered = try await task.value
        XCTAssertEqual(delivered, redirect)
        XCTAssertEqual(model.contentTabs.count, 1, "the sign-in tab closes once the redirect arrives")
        XCTAssertEqual(model.activeTabID, startingTab)
        XCTAssertTrue(model.oauthAuthorizations.isEmpty)
    }

    func testClosingTheSignInTabCancels() async throws {
        let model = makeTestAppModel()
        let presenter = OAuthTabPresenter(host: model)
        let task = Task { try await presenter.authorize(authorizationURL, callback: callback) }
        await waitUntil { !model.oauthAuthorizations.isEmpty }
        model.closeTab(model.activeTabID)
        await assertCancelled(task)
        XCTAssertEqual(model.contentTabs.count, 1)
        XCTAssertTrue(model.oauthAuthorizations.isEmpty)
    }

    func testSignInRouteIsNotPersisted() {
        XCTAssertNil(PersistedRoute(.oauthAuthorization(UUID())))
        XCTAssertNotNil(PersistedRoute(.syncSettings))
    }

    func testAppUsesTheTabPresenterWhereItCanRenderOne() {
        #if (canImport(WebKit) && !BACKEND_GTK && (os(macOS) || os(iOS) || os(visionOS))) || BACKEND_GTK_WEBKIT
        XCTAssertTrue(OAuthTabPresenter.isSupported)
        #else
        XCTAssertFalse(OAuthTabPresenter.isSupported)
        #endif
    }

    // MARK: Helpers

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not met", file: file, line: line)
    }

    private func assertCancelled(_ task: Task<URL, any Error>, file: StaticString = #filePath,
                                 line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch OAuthError.cancelled {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
