import ATProtoKit
import ATAppSync
import Foundation
import Observation

@MainActor
@Observable
final class ProfileAccountService {
    private(set) var account: DID?
    private(set) var handle: String?
    private(set) var isSigningIn = false
    private(set) var errorMessage: String?
    /// Why profile sync is off for the signed-in account, when that is not
    /// an error: the server granted fewer scopes than Hummingbird asked for.
    private(set) var profileSyncNotice: String?
    /// A question to answer before the sign-in page opens, when the server
    /// cannot grant everything Hummingbird asks for.
    private(set) var signInConfirmation: String?
    private(set) var syncService: ProfileSyncService?

    @ObservationIgnored private let oauth: ATProtoOAuthClient
    @ObservationIgnored private let authenticator: ATProtoOAuthAuthenticator
    @ObservationIgnored private let credentialStore: OAuthCredentialStore
    @ObservationIgnored private let changes: ProfileChangeStore
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let peerService: AppSyncPeerService?
    @ObservationIgnored private var localNetworkEnabled: Bool
    @ObservationIgnored private let currentAccountKey: String
    @ObservationIgnored private var signInConfirmationReply: CheckedContinuation<Bool, Never>?

    // An immutable Sendable constant: it needs no actor isolation, and must
    // match the published Web/hummingbird/oauth-client-metadata.json.
    nonisolated static let configuration = OAuthClientConfiguration(
        clientID: URL(string: "https://hummingbird.eightybps.com/oauth-client-metadata.json")!,
        redirectURI: URL(string: "com.eightybps.hummingbird:/oauth/callback")!,
        scopes: [
            "atproto",
            "space:\(profileSpaceType)?authority=self&skey=self&manage=create",
        ]
    )

    /// The permissioned-space type profile sync is stored in.
    nonisolated static let profileSpaceType = "com.eightybps.hummingbird.profile"

    /// Whether a grant includes the profile-space permission. The server may
    /// grant fewer scopes than requested (only `atproto` is required), and
    /// may write the permission's parameters differently, so this matches
    /// the space type rather than the exact requested string.
    nonisolated static func grantsProfileSpace(_ grantedScopes: Set<String>) -> Bool {
        grantedScopes.contains { scope in
            scope == "space:\(profileSpaceType)" || scope.hasPrefix("space:\(profileSpaceType)?")
        }
    }

    nonisolated static let profileSpaceNotGrantedNotice =
        "Your server didn’t grant Hummingbird’s profile-space permission, so profile sync is off."

    nonisolated static let profileSpaceUnsupportedPrompt =
        "Your server doesn’t support Hummingbird’s profile-space permission yet, so profile sync will "
        + "stay off; local network sync still works. Sign in anyway?"

    init(localProfileID: UUID, changes: ProfileChangeStore, library: LibraryStore, plugins: PluginManager,
         peerService: AppSyncPeerService?, peerServiceFailure: (any Error)? = nil,
         localNetworkEnabled: Bool = false,
         oauthPresenter: any ATProtoOAuthPresenter,
         authenticator: ATProtoOAuthAuthenticator? = nil) {
        let oauth = ATProtoOAuthClient(configuration: Self.configuration)
        self.oauth = oauth
        self.authenticator = authenticator ?? ATProtoOAuthAuthenticator(client: oauth, presenter: oauthPresenter)
        credentialStore = OAuthCredentialStore(
            service: "com.eightybps.hummingbird.atproto.\(localProfileID.uuidString.lowercased())",
            vault: AuthKeychain.store
        )
        currentAccountKey = "profile.\(localProfileID.uuidString.lowercased()).atproto.currentAccount"
        self.changes = changes
        self.peerService = peerService
        self.localNetworkEnabled = localNetworkEnabled
        if let mutationLog = changes.mutationLog {
            syncService = ProfileSyncService(
                changes: changes, mutationLog: mutationLog,
                library: library, plugins: plugins,
                peerService: peerService, peerServiceFailure: peerServiceFailure,
                localNetworkEnabled: localNetworkEnabled
            )
            syncService?.bootstrapCurrentProfile()
            changes.setMutationHandler { [weak self] in
                Task { @MainActor in await self?.sync() }
            }
            retryTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sync()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
        restore()
    }

    func signIn(identifier: String) async {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let credential = try await authenticator.signIn(identifier: identifier) { [weak self] prepared in
                await self?.confirmSignIn(prepared) ?? false
            }
            try credentialStore.save(credential)
            UserDefaults.standard.set(credential.session.account.rawValue, forKey: currentAccountKey)
            install(credential)
            syncService?.bootstrapCurrentProfile()
            await syncService?.sync()
        } catch OAuthError.cancelled {
            // The user closed the sign-in page; that is not an error to show.
        } catch is CancellationError {
        } catch {
            // People get one readable line; the full error, with any
            // underlying network errors, goes to the log.
            errorMessage = error.localizedDescription
            print("[atproto sign-in] \(String(reflecting: error))")
        }
    }

    /// Asks before opening the sign-in page when the server does not
    /// support the profile-space permission. When it does, or when it does
    /// not say (no `scopes_supported`), the page opens directly.
    func confirmSignIn(_ prepared: ATProtoPreparedAuthorization) async -> Bool {
        guard prepared.unsupportedScopes.contains(where: { Self.grantsProfileSpace([$0]) }) else { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                signInConfirmationReply?.resume(returning: false)
                signInConfirmationReply = reply
                signInConfirmation = Self.profileSpaceUnsupportedPrompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerSignInConfirmation(false) }
        }
    }

    /// The answer to ``signInConfirmation``: Sign In (true) or Cancel.
    func answerSignInConfirmation(_ proceed: Bool) {
        signInConfirmation = nil
        let reply = signInConfirmationReply
        signInConfirmationReply = nil
        reply?.resume(returning: proceed)
    }

    func sync() async { await syncService?.sync() }

    func setLocalNetworkEnabled(_ enabled: Bool) {
        localNetworkEnabled = enabled
        syncService?.setLocalNetworkEnabled(enabled)
    }

    func peers() async throws -> [AppSyncPeerTrustSummary] {
        if let syncService { return try await syncService.peers() }
        return peerService?.peers(appIDs: [HummingbirdProfileSchema.appID]) ?? []
    }

    func verifyPeer(_ code: AppSyncPeerVerificationCode) async throws {
        if let syncService {
            try await syncService.verifyPeer(code)
        } else if let peerService {
            _ = try peerService.verifyPeer(code, appIDs: [HummingbirdProfileSchema.appID])
        } else {
            throw PairingError.unavailable
        }
    }

    func distrustPeer(_ peer: AppSyncPeer) async throws {
        if let syncService {
            try await syncService.distrustPeer(peer)
        } else if let peerService {
            _ = try peerService.revokeTrust(with: peer)
        } else {
            throw PairingError.unavailable
        }
    }

    func sendCredential(_ auth: SourceAuth, pluginID: String, sourceURL: URL,
                        recipient: AppSyncPeer) async throws {
        guard let syncService else { throw PairingError.unavailable }
        try await syncService.sendCredential(
            auth, pluginID: pluginID, sourceURL: sourceURL, recipient: recipient
        )
    }

    func signOut() {
        if let account {
            do {
                try credentialStore.remove(account: account)
            } catch {
                errorMessage = "Signed out, but the saved session couldn’t be removed: \(error.localizedDescription)"
            }
        }
        UserDefaults.standard.removeObject(forKey: currentAccountKey)
        account = nil
        handle = nil
        profileSyncNotice = nil
        syncService?.disconnectAccount()
    }

    private func restore() {
        guard let raw = UserDefaults.standard.string(forKey: currentAccountKey),
              let did = DID(rawValue: raw) else { return }
        do {
            guard let credential = try credentialStore.load(account: did) else { return }
            install(credential)
        } catch {
            errorMessage = "Your AT Protocol session couldn’t be restored: \(error.localizedDescription)"
        }
    }

    /// Adopts a signed-in account. Profile sync through the account's PDS
    /// is connected only when the profile-space permission was granted.
    func install(_ credential: ATProtoOAuthCredential) {
        account = credential.session.account
        handle = credential.session.handle
        profileSyncNotice = nil
        guard syncService != nil else {
            errorMessage = "The local profile could not be opened."
            return
        }
        guard Self.grantsProfileSpace(credential.session.grantedScopes) else {
            syncService?.disconnectAccount()
            profileSyncNotice = Self.profileSpaceNotGrantedNotice
            return
        }
        syncService?.connect(
            credential: credential, oauth: oauth, credentialStore: credentialStore
        )
    }
}
