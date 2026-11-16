#if canImport(WebKit) && !BACKEND_GTK && os(macOS)
import ATProtoKit
import Foundation
import Network
import WebKit
import XCTest
@testable import HummingbirdKit

/// Drives a real WKWebView through SwiftOpenUI's WebPage navigation hook:
/// a page that navigates to the redirect URI must complete the
/// authorization, and WebKit must never load that URL.
@MainActor
final class OAuthWebViewInterceptionTests: XCTestCase {
    func testScriptNavigationToTheRedirectURIIsIntercepted() async throws {
        let callback = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI))
        let page = "<script>location.href='com.eightybps.hummingbird:/oauth/callback?code=abc&state=xyz'</script>"
        let start = try XCTUnwrap(URL(string: "data:text/html," + page.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        let authorization = OAuthTabAuthorization(authorizationURL: start, callback: callback)
        OAuthWebPageStore.shared.preparePage(for: authorization)
        defer { OAuthWebPageStore.shared.remove(authorization) }

        let deadline = Date().addingTimeInterval(15)
        while !authorization.isFinished, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let delivered = try await authorization.callbackURL()
        XCTAssertEqual(delivered.absoluteString, "com.eightybps.hummingbird:/oauth/callback?code=abc&state=xyz")
        XCTAssertNotEqual(OAuthWebPageStore.shared.currentURL(for: authorization)?.scheme, "com.eightybps.hummingbird")
    }

    /// Authorization servers usually answer the consent form with an HTTP
    /// redirect; WebKit must ask the delegate about that redirect too.
    func testServerRedirectToTheRedirectURIIsIntercepted() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let response = "HTTP/1.1 302 Found\r\nLocation: com.eightybps.hummingbird:/oauth/callback?code=302\r\n"
                    + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        var ports = ready.makeAsyncIterator()
        let nextPort = await ports.next()
        let port = try XCTUnwrap(nextPort)

        let callback = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI))
        let authorization = OAuthTabAuthorization(
            authorizationURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/oauth/authorize/accept")),
            callback: callback
        )
        OAuthWebPageStore.shared.preparePage(for: authorization)
        defer { OAuthWebPageStore.shared.remove(authorization) }
        let deadline = Date().addingTimeInterval(15)
        while !authorization.isFinished, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let delivered = try await authorization.callbackURL()
        XCTAssertEqual(delivered.absoluteString, "com.eightybps.hummingbird:/oauth/callback?code=302")
    }

    // MARK: Single-use authorization requests

    private func waitForFinish(_ authorization: OAuthTabAuthorization) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !authorization.isFinished, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// The request is bound to the device cookie of the browser that loads
    /// it first. The tab must load it exactly once, in a store of its own,
    /// and keep that store's cookie for the consent that follows.
    func testAuthorizationRequestLoadsOnceInItsOwnIsolatedStore() async throws {
        let callbackBase = "com.eightybps.hummingbird:/oauth/callback"
        let server = try FakeAuthorizationServer(callback: callbackBase)
        let authorizationURL = try await server.start()
        defer { server.stop() }

        let callback = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI))
        let authorization = OAuthTabAuthorization(authorizationURL: authorizationURL, callback: callback)
        let otherSignIn = OAuthTabAuthorization(authorizationURL: URL(string: "about:blank")!, callback: callback)
        OAuthWebPageStore.shared.preparePage(for: authorization)
        OAuthWebPageStore.shared.preparePage(for: otherSignIn)
        defer {
            OAuthWebPageStore.shared.remove(authorization)
            OAuthWebPageStore.shared.remove(otherSignIn)
        }
        let store = try XCTUnwrap(OAuthWebPageStore.shared.dataStore(for: authorization))
        XCTAssertFalse(store.isPersistent, "a sign-in must not use a persistent store")
        XCTAssertFalse(store === OAuthWebPageStore.shared.dataStore(for: otherSignIn),
                       "each sign-in must have its own store")

        try await waitForFinish(authorization)
        let delivered = try await authorization.callbackURL()
        XCTAssertEqual(delivered.absoluteString, callbackBase + "?code=granted&state=test-state")
        XCTAssertEqual(server.authorizeRequests, 1, "the single-use request must be loaded exactly once")

        let ownCookies = await store.httpCookieStore.allCookies().map(\.name)
        XCTAssertEqual(ownCookies, ["dev-id"], "the provider's cookie stays in the sign-in's own store")
        let otherCookies = await OAuthWebPageStore.shared.dataStore(for: otherSignIn)?.httpCookieStore.allCookies()
        XCTAssertEqual(otherCookies?.count, 0)
        let shared = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        XCTAssertFalse(shared.contains { $0.domain == "127.0.0.1" }, "nothing leaks into the shared default store")
    }

    /// What the user hit: the page loaded once, but the network delivered
    /// the GET twice (here, the first response is lost and WebKit re-sends
    /// the request). The server binds the request to the first, unseen
    /// device cookie and refuses the second load.
    func testAReplayedAuthorizationLoadIsRefusedAsAnotherDevice() async throws {
        let callbackBase = "com.eightybps.hummingbird:/oauth/callback"
        let server = try FakeAuthorizationServer(
            callback: callbackBase, options: .init(dropFirstAuthorizeResponse: true)
        )
        let authorizationURL = try await server.start()
        defer { server.stop() }
        let callback = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI))
        let authorization = OAuthTabAuthorization(authorizationURL: authorizationURL, callback: callback)
        OAuthWebPageStore.shared.preparePage(for: authorization)
        defer { OAuthWebPageStore.shared.remove(authorization) }

        try await waitForFinish(authorization)
        let delivered = try await authorization.callbackURL()
        XCTAssertEqual(server.authorizeRequests, 2, "WebKit re-sent the GET after the lost response")
        XCTAssertTrue(delivered.absoluteString.contains("error=access_denied"))
    }
}
#endif
