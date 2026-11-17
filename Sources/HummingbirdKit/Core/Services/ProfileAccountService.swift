import ATProtoKit
import ATAppSync
import Foundation
import os
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
    /// Emoji verifications in progress or just finished, from either side.
    private(set) var verifications: [AppSyncPeerVerification] = []
    @ObservationIgnored private var verificationWatch: Task<Void, Never>?

    @ObservationIgnored private let oauth: ATProtoOAuthClient
    @ObservationIgnored private let authenticator: ATProtoOAuthAuthenticator
    @ObservationIgnored private let credentialStore: OAuthCredentialStore
    @ObservationIgnored private let changes: ProfileChangeStore
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private let peerService: AppSyncPeerService?
    @ObservationIgnored private var localNetworkEnabled: Bool
    @ObservationIgnored private let currentAccountKey: String
    @ObservationIgnored private var signInConfirmationReply: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let preferences: PreferencesDomain

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

    init(localProfileID: UUID, stores: AppDataStores,
         changes: ProfileChangeStore, library: LibraryStore, plugins: PluginManager,
         peerService: AppSyncPeerService?, peerServiceFailure: (any Error)? = nil,
         localNetworkEnabled: Bool = false,
         oauthPresenter: any ATProtoOAuthPresenter,
         authenticator: ATProtoOAuthAuthenticator? = nil) {
        let oauth = ATProtoOAuthClient(configuration: Self.configuration)
        self.oauth = oauth
        self.authenticator = authenticator ?? ATProtoOAuthAuthenticator(client: oauth, presenter: oauthPresenter)
        credentialStore = OAuthCredentialStore(
            service: "com.eightybps.hummingbird.atproto.\(localProfileID.uuidString.lowercased())",
            vault: stores.credentialStore
        )
        currentAccountKey = "profile.\(localProfileID.uuidString.lowercased()).atproto.currentAccount"
        preferences = stores.preferences
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
        let signposter = OSSignposter.account
        let signpost = signposter.beginInterval("OAuthSignIn", id: signposter.makeSignpostID())
        var outcome = "failed"
        defer {
            isSigningIn = false
            signposter.endInterval("OAuthSignIn", signpost, "\(outcome, privacy: .public)")
        }
        do {
            let authorize = signposter.beginInterval("OAuthAuthorize", id: signposter.makeSignpostID())
            let credential: ATProtoOAuthCredential
            do {
                credential = try await authenticator.signIn(identifier: identifier) { [weak self] prepared in
                    await self?.confirmSignIn(prepared) ?? false
                }
                signposter.endInterval("OAuthAuthorize", authorize)
            } catch {
                signposter.endInterval("OAuthAuthorize", authorize, "failed")
                throw error
            }
            let save = signposter.beginInterval("SaveCredential", id: signposter.makeSignpostID())
            defer { signposter.endInterval("SaveCredential", save) }
            try await Self.save(credential, in: credentialStore)
            Logger.account.notice("signed_in")
            preferences.defaults.set(credential.session.account.rawValue, forKey: currentAccountKey)
            install(credential)
            syncService?.bootstrapCurrentProfile()
            await syncService?.sync()
            outcome = "ok"
        } catch OAuthError.cancelled {
            outcome = "cancelled"
            // The user closed the sign-in page; that is not an error to show.
        } catch is CancellationError {
        } catch {
            // People get one readable line; the full error, with any
            // underlying network errors, goes to the log.
            errorMessage = error.localizedDescription
            Logger.account.error("sign_in_failed error=\(String(reflecting: type(of: error)), privacy: .public) detail=\(String(reflecting: error))")
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

    /// Keeps `verifications` current, so a verification started by another
    /// instance can be shown wherever the user is. Safe to call repeatedly.
    func watchVerifications() {
        guard verificationWatch == nil, let peerService else { return }
        verifications = peerService.verifications()
        verificationWatch = Task { [weak self] in
            for await _ in peerService.changes() {
                self?.verifications = peerService.verifications()
            }
        }
    }

    /// Starts emoji verification with a reachable instance.
    func startVerification(with peer: AppSyncPeerTrustSummary) async throws {
        guard let peerService, let registration = peer.registration else {
            throw AppSyncPeerVerificationFailure.unreachable
        }
        _ = try await peerService.startVerification(with: registration)
    }

    func confirmVerification(_ id: UUID) async throws {
        try await peerService?.confirmVerification(id)
    }

    func cancelVerification(_ id: UUID) async {
        await peerService?.cancelVerification(id)
    }

    func dismissVerification(_ id: UUID) {
        peerService?.dismissVerification(id)
    }

    /// Fires whenever `peers()` may return something different: an instance
    /// appeared, changed or left the local network, or trust changed.
    func peerChanges() -> AsyncStream<Void> {
        peerService?.changes() ?? AsyncStream { $0.finish() }
    }

    func peers() async throws -> [AppSyncPeerTrustSummary] {
        if let syncService { return try await syncService.peers() }
        guard let peerService else { return [] }
        return await PeerTrust.peers(peerService)
    }

    func verifyPeer(_ code: AppSyncPeerVerificationCode) async throws {
        if let syncService {
            try await syncService.verifyPeer(code)
        } else if let peerService {
            try await PeerTrust.verify(code, with: peerService)
        } else {
            throw PairingError.unavailable
        }
    }

    func distrustPeer(_ peer: AppSyncPeer) async throws {
        if let syncService {
            try await syncService.distrustPeer(peer)
        } else if let peerService {
            try await PeerTrust.revoke(peer, with: peerService)
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
        restoreTask?.cancel()
        if let account {
            let credentialStore = credentialStore
            Task { [weak self] in
                do { try await Self.remove(account, from: credentialStore) }
                catch {
                    self?.errorMessage = "Signed out, but the saved session couldn’t be removed: \(error.localizedDescription)"
                }
            }
        }
        preferences.defaults.removeObject(forKey: currentAccountKey)
        account = nil
        handle = nil
        profileSyncNotice = nil
        syncService?.disconnectAccount()
    }

    /// Reads the saved session away from the main actor; keychain reads can
    /// take a while, and the login keychain may even ask first.
    private func restore() {
        guard let raw = preferences.defaults.string(forKey: currentAccountKey),
              let did = DID(rawValue: raw) else { return }
        let credentialStore = credentialStore
        restoreTask = Task { [weak self] in
            let result: Result<ATProtoOAuthCredential?, any Error>
            do { result = .success(try await Self.load(did, from: credentialStore)) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.account == nil else { return }
            switch result {
            case .success(let credential?): self.install(credential)
            case .success(nil): break
            case .failure(let error):
                self.errorMessage = "Your AT Protocol session couldn’t be restored: \(error.localizedDescription)"
            }
        }
    }

    /// Waits for the saved session, if any, to be restored.
    func restored() async { await restoreTask?.value }

    @concurrent
    private static func load(_ account: DID, from store: OAuthCredentialStore) async throws -> ATProtoOAuthCredential? {
        try store.load(account: account)
    }

    @concurrent
    private static func save(_ credential: ATProtoOAuthCredential, in store: OAuthCredentialStore) async throws {
        try store.save(credential)
    }

    @concurrent
    private static func remove(_ account: DID, from store: OAuthCredentialStore) async throws {
        try store.remove(account: account)
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
