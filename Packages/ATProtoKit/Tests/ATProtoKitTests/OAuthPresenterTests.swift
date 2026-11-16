import AuthenticationServices
import Foundation
import XCTest
@testable import ATProtoKit

final class OAuthPresenterTests: XCTestCase {
    func testCustomSchemeCallbackMatching() throws {
        let matcher = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: XCTUnwrap(URL(string: "com.example.app:/oauth/callback"))))
        XCTAssertEqual(matcher, .customScheme("com.example.app"))
        XCTAssertTrue(matcher.matches(try XCTUnwrap(URL(string: "com.example.app:/oauth/callback?code=1&state=2"))))
        XCTAssertTrue(matcher.matches(try XCTUnwrap(URL(string: "COM.EXAMPLE.APP:/oauth/callback"))))
        XCTAssertFalse(matcher.matches(try XCTUnwrap(URL(string: "https://pds.example.net/oauth/authorize"))))
        XCTAssertFalse(matcher.matches(try XCTUnwrap(URL(string: "com.example.other:/oauth/callback"))))
    }

    func testHTTPSCallbackMatching() throws {
        let matcher = try XCTUnwrap(OAuthCallbackMatcher(redirectURI: XCTUnwrap(URL(string: "https://app.example.com/callback"))))
        XCTAssertTrue(matcher.matches(try XCTUnwrap(URL(string: "https://APP.example.com/callback?code=1"))))
        XCTAssertFalse(matcher.matches(try XCTUnwrap(URL(string: "https://app.example.com/other"))))
        XCTAssertFalse(matcher.matches(try XCTUnwrap(URL(string: "http://app.example.com/callback"))))
        XCTAssertNil(OAuthCallbackMatcher(redirectURI: try XCTUnwrap(URL(string: "http://app.example.com/callback"))))
    }

    /// AuthenticationServices delivers its completion on a private XPC queue.
    /// The handler must be callable there without a main-actor isolation trap.
    func testSessionCompletionResumesFromABackgroundQueue() async throws {
        let callback = try XCTUnwrap(URL(string: "com.example.app:/oauth/callback?code=1"))
        let delivered = try await withCheckedThrowingContinuation { continuation in
            let completion = WebAuthenticationSessionPresenter.completion(resuming: continuation)
            DispatchQueue(label: "test.authentication-services-xpc").async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                completion(callback, nil)
            }
        }
        XCTAssertEqual(delivered, callback)
    }

    func testSessionCancellationBecomesOAuthCancelled() async {
        #if canImport(Darwin)
        let cancelled = ASWebAuthenticationSessionError(.canceledLogin)
        #else
        let cancelled = ASWebAuthenticationSessionError.canceledLogin
        #endif
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                let completion = WebAuthenticationSessionPresenter.completion(resuming: continuation)
                DispatchQueue.global().async { completion(nil, cancelled) }
            }
            XCTFail("Expected cancellation")
        } catch OAuthError.cancelled {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testOtherSessionErrorsPassThrough() {
        let failure = URLError(.notConnectedToInternet)
        XCTAssertEqual((WebAuthenticationSessionPresenter.sessionError(failure) as? URLError)?.code, .notConnectedToInternet)
        guard case OAuthError.invalidCallback = WebAuthenticationSessionPresenter.sessionError(nil) else {
            return XCTFail("A missing URL without an error is an invalid callback")
        }
    }
}
