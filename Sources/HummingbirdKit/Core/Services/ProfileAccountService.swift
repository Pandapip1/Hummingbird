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
    private(set) var syncService: ProfileSyncService?

    @ObservationIgnored private let oauth: ATProtoOAuthClient
    @ObservationIgnored private let authenticator: ATProtoOAuthAuthenticator
    @ObservationIgnored private let credentialStore: OAuthCredentialStore
    @ObservationIgnored private let changes: ProfileChangeStore
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let peerService: AppSyncPeerService?
    @ObservationIgnored private var localNetworkEnabled: Bool

    static let configuration = OAuthClientConfiguration(
        clientID: URL(string: "https://eightybps.com/oauth-client-metadata.json")!,
        redirectURI: URL(string: "com.eightybps.hummingbird:/oauth/callback")!,
        scopes: [
            "atproto",
            "space:com.eightybps.hummingbird.profile?authority=self&skey=self&manage=create",
        ]
    )

    init(changes: ProfileChangeStore, library: LibraryStore, plugins: PluginManager,
         peerService: AppSyncPeerService?, localNetworkEnabled: Bool = false) {
        let oauth = ATProtoOAuthClient(configuration: Self.configuration)
        self.oauth = oauth
        authenticator = ATProtoOAuthAuthenticator(client: oauth)
        let keychainAccessGroup = Bundle.main.object(
            forInfoDictionaryKey: "ATProtoKeychainAccessGroup"
        ) as? String
        credentialStore = OAuthCredentialStore(
            service: "com.eightybps.hummingbird.atproto",
            accessGroup: keychainAccessGroup
        )
        self.changes = changes
        self.peerService = peerService
        self.localNetworkEnabled = localNetworkEnabled
        if let mutationLog = changes.mutationLog {
            syncService = ProfileSyncService(
                changes: changes, mutationLog: mutationLog,
                library: library, plugins: plugins, peerService: peerService,
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
            let credential = try await authenticator.signIn(identifier: identifier)
            try credentialStore.save(credential)
            UserDefaults.standard.set(credential.session.account.rawValue, forKey: "atproto.currentAccount")
            install(credential)
            syncService?.bootstrapCurrentProfile()
            await syncService?.sync()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        if let account { try? credentialStore.remove(account: account) }
        UserDefaults.standard.removeObject(forKey: "atproto.currentAccount")
        account = nil
        handle = nil
        syncService?.disconnectAccount()
    }

    private func restore() {
        guard let raw = UserDefaults.standard.string(forKey: "atproto.currentAccount"),
              let did = DID(rawValue: raw), let credential = try? credentialStore.load(account: did) else { return }
        install(credential)
    }

    private func install(_ credential: ATProtoOAuthCredential) {
        account = credential.session.account
        handle = credential.session.handle
        guard syncService != nil else {
            errorMessage = "The local profile could not be opened."
            return
        }
        syncService?.connect(
            credential: credential, oauth: oauth, credentialStore: credentialStore
        )
    }
}
