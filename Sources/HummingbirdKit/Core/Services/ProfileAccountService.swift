import ATProtoKit
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
    @ObservationIgnored private let mutationJournal: ProfileMutationJournal
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var plugins: PluginManager?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    static let configuration = OAuthClientConfiguration(
        clientID: URL(string: "https://eightybps.com/oauth-client-metadata.json")!,
        redirectURI: URL(string: "com.eightybps.hummingbird:/oauth/callback")!,
        scopes: [
            "atproto",
            "space:com.eightybps.hummingbird.profile?authority=self&skey=self&manage=create",
        ]
    )

    init(mutationJournal: ProfileMutationJournal, library: LibraryStore, plugins: PluginManager) {
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
        self.mutationJournal = mutationJournal
        self.library = library
        self.plugins = plugins
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

    func signOut() {
        if let account { try? credentialStore.remove(account: account) }
        UserDefaults.standard.removeObject(forKey: "atproto.currentAccount")
        account = nil
        handle = nil
        syncService = nil
        retryTask?.cancel()
        retryTask = nil
        mutationJournal.setMutationHandler(nil)
        mutationJournal.deactivate()
    }

    private func restore() {
        guard let raw = UserDefaults.standard.string(forKey: "atproto.currentAccount"),
              let did = DID(rawValue: raw), let credential = try? credentialStore.load(account: did) else { return }
        install(credential)
    }

    private func install(_ credential: ATProtoOAuthCredential) {
        account = credential.session.account
        handle = credential.session.handle
        guard let library, let plugins else { return }
        let journal: OfflineMutationJournal
        do {
            journal = try mutationJournal.activate(account: credential.session.account)
        } catch {
            errorMessage = error.localizedDescription
            syncService = nil
            return
        }
        syncService = ProfileSyncService(
            credential: credential, oauth: oauth, credentialStore: credentialStore,
            mutationJournal: mutationJournal, journal: journal, library: library, plugins: plugins
        )
        mutationJournal.setMutationHandler { [weak self] in
            Task { @MainActor in await self?.sync() }
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
