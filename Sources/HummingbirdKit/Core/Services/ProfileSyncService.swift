import ATProtoKit
import Foundation
import Observation

@MainActor
@Observable
final class ProfileSyncService {
    enum State: Equatable { case idle, syncing, offline, failed(String) }

    private(set) var state: State = .idle
    private(set) var lastSyncedAt: Date?

    @ObservationIgnored private let owner: DID
    @ObservationIgnored private let engine: SpaceSyncEngine
    @ObservationIgnored private let spaces: SpacesClient
    @ObservationIgnored private let mutationJournal: ProfileMutationJournal
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var plugins: PluginManager?

    init(credential: ATProtoOAuthCredential, oauth: ATProtoOAuthClient,
         credentialStore: OAuthCredentialStore?, mutationJournal: ProfileMutationJournal,
         journal: OfflineMutationJournal,
         library: LibraryStore, plugins: PluginManager) {
        owner = credential.session.account
        let authorization = DPoPAuthorization(credential: credential, oauth: oauth, store: credentialStore)
        let xrpc = XRPCClient(service: credential.session.pds, authorization: authorization)
        let spaces = SpacesClient(xrpc: xrpc)
        let space = SpaceReference(
            authority: credential.session.account, type: HummingbirdProfileSchema.spaceType,
            key: HummingbirdProfileSchema.spaceKey
        )
        self.spaces = spaces
        engine = SpaceSyncEngine(spaces: spaces, journal: journal,
                                 repo: credential.session.account, space: space,
                                 journalCollection: HummingbirdProfileSchema.journal)
        self.mutationJournal = mutationJournal
        self.library = library
        self.plugins = plugins
    }

    func bootstrapCurrentProfile() {
        guard let library, let plugins, mutationJournal.journal?.isEmpty == true else { return }
        for value in library.subscriptions { mutationJournal.put(.subscription(value)) }
        for value in library.playlists { mutationJournal.put(.playlist(value)) }
        for (position, value) in library.watchLater.enumerated() {
            mutationJournal.put(.watchLater(.init(video: value, position: position)))
        }
        for value in library.history { mutationJournal.put(.history(value)) }
        for value in plugins.installed {
            if let synced = SyncedPlugin(value) { mutationJournal.put(.plugin(synced)) }
        }
    }

    func sync() async {
        guard state != .syncing else { return }
        state = .syncing
        do {
            try await ensureOwnerSpace()
            // Pull before pushing so a newer edit from another device cannot be
            // overwritten merely because this device happened to reconnect.
            let remote = try await engine.pull()
            try await apply(remote)
            try await engine.pushPending()
            lastSyncedAt = Date()
            state = .idle
        } catch let error as URLError where [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .timedOut,
        ].contains(error.code) {
            state = .offline
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func ensureOwnerSpace() async throws {
        do {
            _ = try await spaces.createOwnerSpace(
                type: HummingbirdProfileSchema.spaceType, key: HummingbirdProfileSchema.spaceKey
            )
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {
            return
        }
    }

    private func apply(_ records: [JournalMutation]) async throws {
        guard let library, let plugins else { return }
        for event in records {
            guard let journal = mutationJournal.journal else { return }
            guard try journal.merge(event, needsUpload: false) else { continue }
            if event.operation == .delete {
                if event.collection == HummingbirdProfileSchema.plugin {
                    plugins.applyRemoteDelete(key: event.recordKey)
                } else {
                    library.applyRemoteDelete(collection: event.collection, key: event.recordKey)
                }
            } else if let payload = event.value,
                      let entity = try ProfileEntity.decode(collection: event.collection, payload: payload) {
                switch entity {
                case .plugin(let plugin): try await plugins.applyRemote(plugin)
                default: library.applyRemote(entity, deleted: false)
                }
            }
        }
    }
}
