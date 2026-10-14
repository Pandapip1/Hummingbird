import ATProtoKit
import ATAppSync
import Foundation
import Observation

@MainActor
@Observable
final class ProfileSyncService {
    enum State: Equatable { case idle, syncing, offline, failed(String) }

    private(set) var state: State = .idle
    private(set) var lastSyncedAt: Date?

    @ObservationIgnored private let owner: DID
    @ObservationIgnored private let appSync: AppSyncClient
    @ObservationIgnored private let spaces: SpacesClient
    @ObservationIgnored private let changes: ProfileChangeStore
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var plugins: PluginManager?

    init(credential: ATProtoOAuthCredential, oauth: ATProtoOAuthClient,
         credentialStore: OAuthCredentialStore?, changes: ProfileChangeStore,
         mutationLog: AppSyncMutationLog,
         library: LibraryStore, plugins: PluginManager,
         peerService: AppSyncPeerService?) {
        owner = credential.session.account
        let authorization = DPoPAuthorization(credential: credential, oauth: oauth, store: credentialStore)
        let xrpc = XRPCClient(service: credential.session.pds, authorization: authorization)
        let spaces = SpacesClient(xrpc: xrpc)
        let space = SpaceReference(
            authority: credential.session.account, type: HummingbirdProfileSchema.spaceType,
            key: HummingbirdProfileSchema.spaceKey
        )
        self.spaces = spaces
        appSync = AppSyncClient(
            spaces: spaces, mutationLog: mutationLog, repo: credential.session.account, space: space,
            appID: HummingbirdProfileSchema.appID, messaging: peerService
        )
        self.changes = changes
        self.library = library
        self.plugins = plugins
    }

    func bootstrapCurrentProfile() {
        guard let library, let plugins, changes.mutationLog?.isEmpty == true else { return }
        for value in library.subscriptions { changes.put(.subscription(value)) }
        for value in library.playlists { changes.put(.playlist(value)) }
        for (position, value) in library.watchLater.enumerated() {
            changes.put(.watchLater(.init(video: value, position: position)))
        }
        for value in library.history { changes.put(.history(value)) }
        for value in plugins.installed {
            if let synced = SyncedPlugin(value) { changes.put(.plugin(synced)) }
        }
    }

    func sync() async {
        guard state != .syncing else { return }
        state = .syncing
        do {
            try await ensureOwnerSpace()
            // Pull before pushing so a newer edit from another device cannot be
            // overwritten merely because this device happened to reconnect.
            let remote = try await appSync.pullMutations()
            try await apply(remote)
            try await appSync.pushMutations()
            let messages = try await appSync.syncMessages()
            try await applyMessages(messages)
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

    func sendCredential(_ auth: SourceAuth, pluginID: String, sourceURL: URL,
                        recipient: AppSyncPeer) async throws {
        let payload = PairingPayload.credentials(.init(
            pluginID: pluginID, pluginSourceURL: sourceURL, auth: auth
        ))
        try await appSync.sendMessage(try .encoding(payload), to: recipient)
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

    private func apply(_ records: [AppSyncMutation]) async throws {
        guard let library, let plugins else { return }
        for event in records {
            guard let mutationLog = changes.mutationLog else { return }
            guard try mutationLog.merge(event, needsUpload: false) else { continue }
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

    private func applyMessages(_ messages: [AppSyncMessage]) async throws {
        guard let plugins else { return }
        for message in messages {
            guard case .credentials(let transfer) = try message.payload.decode(PairingPayload.self),
                  !transfer.auth.isEmpty,
                  plugins.plugin(transfer.pluginID)?.config.sourceUrl == transfer.pluginSourceURL.absoluteString
            else { continue }
            plugins.saveAuth(transfer.auth, pluginID: transfer.pluginID)
            try await appSync.acknowledgeMessage(id: message.id)
        }
    }
}
