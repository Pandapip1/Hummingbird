import AuthenticationServices
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Shows an authorization server's page to the user and reports where it
/// redirected. Apps that want sign-in to happen somewhere other than the
/// system web authentication sheet (for example inside their own browser
/// tabs) supply their own presenter.
@MainActor
public protocol ATProtoOAuthPresenter {
    /// Presents `authorizationURL` and returns the first URL the page
    /// navigates to that `callback` matches. That navigation must not be
    /// loaded. Throws ``OAuthError/cancelled`` when the user dismisses the
    /// page, and must stop presenting when the calling task is cancelled.
    func authorize(_ authorizationURL: URL, callback: OAuthCallbackMatcher) async throws -> URL
}

/// Complete, provider-neutral atproto sign-in: resolves the account, presents
/// its authorization server, and exchanges the callback for a credential.
@MainActor
public final class ATProtoOAuthAuthenticator {
    private let client: ATProtoOAuthClient
    private let presenter: any ATProtoOAuthPresenter

    /// `presenter` defaults to the system web authentication session.
    public init(client: ATProtoOAuthClient,
                presenter: any ATProtoOAuthPresenter = WebAuthenticationSessionPresenter()) {
        self.client = client
        self.presenter = presenter
    }

    public func signIn(identifier: String) async throws -> ATProtoOAuthCredential {
        let pending = try await client.begin(identifier: identifier)
        let callbackURL = try await presenter.authorize(pending.authorizationURL, callback: pending.callback)
        return try await client.complete(pending, callbackURL: callbackURL)
    }
}

/// The default presenter: the platform's `ASWebAuthenticationSession`. On
/// Apple platforms this is the system authentication sheet; SwiftOpenUI
/// supplies the same API elsewhere.
@MainActor
public final class WebAuthenticationSessionPresenter: ATProtoOAuthPresenter {
    /// Whether the session should avoid sharing cookies with the user's
    /// browser. Shared by default, so an existing provider login is reused.
    public var prefersEphemeralWebBrowserSession = false
    private var activeSession: ASWebAuthenticationSession?
    #if os(macOS) || os(iOS) || os(visionOS)
    private let presentationProvider = PresentationProvider()
    #endif

    public init() {}

    public func authorize(_ authorizationURL: URL, callback: OAuthCallbackMatcher) async throws -> URL {
        #if os(tvOS)
        throw OAuthError.authorizationFailed(
            "tvOS does not provide system web authentication; authorize this instance from a companion device."
        )
        #else
        let sessionCallback: ASWebAuthenticationSession.Callback
        switch callback {
        case .customScheme(let scheme): sessionCallback = .customScheme(scheme)
        case .https(let host, let path): sessionCallback = .https(host: host, path: path)
        }
        defer { activeSession = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authorizationURL, callback: sessionCallback,
                    completionHandler: Self.completion(resuming: continuation)
                )
                session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
                #if os(macOS) || os(iOS) || os(visionOS)
                session.presentationContextProvider = presentationProvider
                #endif
                activeSession = session
                guard session.start() else {
                    continuation.resume(throwing: OAuthError.authorizationFailed(
                        "The system browser session could not start."
                    ))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.activeSession?.cancel() }
        }
        #endif
    }

    /// AuthenticationServices calls the completion handler on a private XPC
    /// queue, not the main actor. A closure written inside `authorize` would
    /// inherit main-actor isolation, and the Swift 6 runtime traps when such a
    /// closure runs off the main queue. Built here, in a nonisolated context,
    /// the closure is nonisolated; it only resumes the continuation, which is
    /// safe from any thread.
    nonisolated static func completion(
        resuming continuation: CheckedContinuation<URL, any Error>
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { url, error in
            if let url {
                continuation.resume(returning: url)
            } else {
                continuation.resume(throwing: sessionError(error))
            }
        }
    }

    /// Maps the session's user-cancelled error to ``OAuthError/cancelled``.
    nonisolated static func sessionError(_ error: (any Error)?) -> any Error {
        guard let error else { return OAuthError.invalidCallback }
        #if os(tvOS)
        return error
        #else
        switch error {
        case ASWebAuthenticationSessionError.canceledLogin: return OAuthError.cancelled
        default: return error
        }
        #endif
    }
}

#if os(macOS) || os(iOS) || os(visionOS)
@MainActor
private final class PresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #endif
    }
}
#endif
