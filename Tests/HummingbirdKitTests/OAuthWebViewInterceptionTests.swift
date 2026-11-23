#if canImport(WebKit) && !BACKEND_GTK && os(macOS)
import ATProtoKit
import Foundation
import Network
import Synchronization
import WebKit
import XCTest
@testable import HummingbirdKit

/// Drives a real WKWebView through SwiftOpenUI's WebPage navigation hook:
/// a page that navigates to the redirect URI must complete the
/// authorization, and WebKit must never load that URL.
///
/// Every wait here is bounded: a page that never completes, a listener that
/// never becomes ready or a WebKit store that never answers fails the test
/// with what was seen, instead of hanging the run.
@MainActor
final class OAuthWebViewInterceptionTests: XCTestCase {
    struct Timeout: Error, CustomStringConvertible { let description: String }

    /// The authorization's redirect, waiting at most `seconds` for it. `callbackURL()` itself
    /// suspends until the authorization finishes, so it is only called once it has.
    private func redirect(of authorization: OAuthTabAuthorization, within seconds: TimeInterval = 20,
                          seen: @autoclosure () -> String = "") async throws -> URL {
        let deadline = Date().addingTimeInterval(seconds)
        while !authorization.isFinished, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard authorization.isFinished else {
            let page = OAuthWebPageStore.shared.currentURL(for: authorization)?.absoluteString ?? "none"
            throw Timeout(description: "no redirect within \(seconds) s (page at \(page)) \(seen())")
        }
        return try await authorization.callbackURL()
    }

    /// `operation`'s result, or a failure after `seconds`; the operation is left to finish on its own.
    private func bounded<T: Sendable>(_ what: String, seconds: TimeInterval = 10,
                                      _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            let resume: @Sendable (Result<T, any Error>) -> Void = { result in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            Task { @MainActor in
                do { resume(.success(try await operation())) } catch { resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resume(.failure(Timeout(description: "\(what) did not answer within \(seconds) s")))
            }
        }
    }

    func testScriptNavigationToTheRedirectURIIsIntercepted() async throws {
        let callback = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI))
        let page = "<script>location.href='com.eightybps.hummingbird:/oauth/callback?code=abc&state=xyz'</script>"
        // Served by an authorization server (on loopback): the sign-in tab only loads that site.
        let server = try LoopbackHTTPServer(body: page, contentType: "text/html")
        defer { server.stop() }
        let start = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/oauth/authorize"))
        let authorization = OAuthTabAuthorization(authorizationURL: start, callback: callback)
        OAuthWebPageStore.shared.preparePage(for: authorization)
        defer { OAuthWebPageStore.shared.remove(authorization) }

        let delivered = try await redirect(of: authorization, within: 15, seen: "requests: \(server.requests.count)")
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
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { continuation.yield(port) }
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        let port = try await bounded("the listener") {
            var ports = ready.makeAsyncIterator()
            guard let port = await ports.next() else { throw Timeout(description: "the listener failed") }
            return port
        }

        let callback = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: ProfileAccountService.configuration.redirectURI))
        let authorization = OAuthTabAuthorization(
            authorizationURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/oauth/authorize/accept")),
            callback: callback
        )
        OAuthWebPageStore.shared.preparePage(for: authorization)
        defer { OAuthWebPageStore.shared.remove(authorization) }
        let delivered = try await redirect(of: authorization, within: 15)
        XCTAssertEqual(delivered.absoluteString, "com.eightybps.hummingbird:/oauth/callback?code=302")
    }

    // MARK: Single-use authorization requests

    private func cookieNames(_ store: WKWebsiteDataStore?, _ what: String) async throws -> [String]? {
        guard let store else { return nil }
        return try await bounded("\(what) cookie store") { await store.httpCookieStore.allCookies().map(\.name) }
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

        let delivered = try await redirect(of: authorization, seen: "server saw \(server.requestLog)")
        XCTAssertEqual(delivered.absoluteString, callbackBase + "?code=granted&state=test-state")
        XCTAssertEqual(server.authorizeRequests, 1, "the single-use request must be loaded exactly once: \(server.requestLog)")

        let ownCookies = try await cookieNames(store, "the sign-in's")
        XCTAssertEqual(ownCookies, ["dev-id"], "the provider's cookie stays in the sign-in's own store")
        let otherCookies = try await cookieNames(OAuthWebPageStore.shared.dataStore(for: otherSignIn), "the other sign-in's")
        XCTAssertEqual(otherCookies?.count, 0)
        let leaked = try await bounded("the default cookie store") {
            await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter { $0.domain == "127.0.0.1" }.count
        }
        XCTAssertEqual(leaked, 0, "nothing leaks into the shared default store")
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

        let delivered = try await redirect(of: authorization, seen: "server saw \(server.requestLog)")
        XCTAssertEqual(server.authorizeRequests, 2, "WebKit re-sent the GET after the lost response: \(server.requestLog)")
        XCTAssertTrue(delivered.absoluteString.contains("error=access_denied"))
    }
}
#endif
