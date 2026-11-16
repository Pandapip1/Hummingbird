#if canImport(WebKit) && !BACKEND_GTK && os(macOS)
import ATProtoKit
import Foundation
import Network
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
}
#endif
