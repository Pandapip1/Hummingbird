import AuthenticationServices
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Complete, provider-neutral atproto sign-in presentation. On Apple this uses
/// the system AuthenticationServices framework; SwiftOpenUI supplies the same
/// API on other supported platforms.
@MainActor
public final class ATProtoOAuthAuthenticator {
    private let client: ATProtoOAuthClient
    private var activeSession: ASWebAuthenticationSession?
    #if os(macOS) || os(iOS) || os(visionOS)
    private let presentationProvider = PresentationProvider()
    #endif

    public init(client: ATProtoOAuthClient) { self.client = client }

    public func signIn(identifier: String) async throws -> ATProtoOAuthCredential {
        let pending = try await client.begin(identifier: identifier)
        let callback: ASWebAuthenticationSession.Callback
        switch pending.callback {
        case .customScheme(let scheme): callback = .customScheme(scheme)
        case .https(let host, let path): callback = .https(host: host, path: path)
        }
        let callbackURL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: pending.authorizationURL, callback: callback
                ) { [weak self] url, error in
                    Task { @MainActor in self?.activeSession = nil }
                    if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? OAuthError.invalidCallback) }
                }
                session.prefersEphemeralWebBrowserSession = false
                #if os(macOS) || os(iOS) || os(visionOS)
                session.presentationContextProvider = presentationProvider
                #endif
                activeSession = session
                guard session.start() else {
                    activeSession = nil
                    continuation.resume(throwing: OAuthError.authorizationFailed("The system browser session could not start."))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.activeSession?.cancel() }
        }
        return try await client.complete(pending, callbackURL: callbackURL)
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
