import ATProtoKit
import Foundation

/// One atproto authorization shown in a browser tab. The tab's web view asks
/// it about every navigation; the redirect back to the app is cancelled and
/// completes the sign-in instead of loading.
@MainActor
final class OAuthTabAuthorization: Identifiable {
    let id = UUID()
    let authorizationURL: URL
    let callback: OAuthCallbackMatcher
    private var continuation: CheckedContinuation<URL, any Error>?
    private var result: Result<URL, any Error>?

    init(authorizationURL: URL, callback: OAuthCallbackMatcher) {
        self.authorizationURL = authorizationURL
        self.callback = callback
    }

    var isFinished: Bool { result != nil }

    /// Whether the web view should load `url`. The redirect URI is never
    /// loaded: its query holds the authorization code, and it is not a page.
    func shouldLoad(_ url: URL) -> Bool {
        guard callback.matches(url) else { return true }
        finish(.success(url))
        return false
    }

    /// The user closed the tab, or the sign-in task was cancelled.
    func cancel() { finish(.failure(OAuthError.cancelled)) }

    /// Suspends until the redirect arrives or the authorization is cancelled.
    func callbackURL() async throws -> URL {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(_ outcome: Result<URL, any Error>) {
        guard result == nil else { return }
        result = outcome
        continuation?.resume(with: outcome)
        continuation = nil
    }
}

/// Where an ``OAuthTabPresenter`` shows its authorization pages: the app's
/// browser tabs.
@MainActor
protocol OAuthTabHost: AnyObject {
    func presentOAuthAuthorization(_ authorization: OAuthTabAuthorization)
    func dismissOAuthAuthorization(_ authorization: OAuthTabAuthorization)
}

/// Signs in to atproto inside one of Hummingbird's own browser tabs rather
/// than the system authentication sheet.
@MainActor
final class OAuthTabPresenter: ATProtoOAuthPresenter {
    /// Whether this build can render the authorization page in a tab. Other
    /// builds keep ATProtoKit's default system web authentication session.
    static var isSupported: Bool {
        #if (canImport(WebKit) && !BACKEND_GTK && (os(macOS) || os(iOS) || os(visionOS))) || BACKEND_GTK_WEBKIT
        true
        #else
        false
        #endif
    }

    weak var host: (any OAuthTabHost)?

    init(host: (any OAuthTabHost)? = nil) { self.host = host }

    func authorize(_ authorizationURL: URL, callback: OAuthCallbackMatcher) async throws -> URL {
        guard let host else { throw OAuthError.authorizationFailed("The app has no window to sign in from.") }
        let authorization = OAuthTabAuthorization(authorizationURL: authorizationURL, callback: callback)
        host.presentOAuthAuthorization(authorization)
        defer { host.dismissOAuthAuthorization(authorization) }
        return try await withTaskCancellationHandler {
            try await authorization.callbackURL()
        } onCancel: {
            Task { @MainActor in authorization.cancel() }
        }
    }
}
