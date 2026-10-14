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

    @ObservationIgnored private var appSync: AppSyncClient?
    @ObservationIgnored private var spaces: SpacesClient?
    @ObservationIgnored private let lanSync: AppSyncLANClient?
    @ObservationIgnored private let changes: ProfileChangeStore
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var plugins: PluginManager?
    @ObservationIgnored private let peerService: AppSyncPeerService?

    init(changes: ProfileChangeStore, mutationLog: AppSyncMutationLog,
         library: LibraryStore, plugins: PluginManager,
         peerService: AppSyncPeerService?) {
        lanSync = peerService.map {
            AppSyncLANClient(
                messaging: $0, journal: mutationLog, appID: HummingbirdProfileSchema.appID
            )
        }
        self.changes = changes
        self.library = library
        self.plugins = plugins
        self.peerService = peerService
    }

    func connect(credential: ATProtoOAuthCredential, oauth: ATProtoOAuthClient,
                 credentialStore: OAuthCredentialStore?) {
        let authorization = DPoPAuthorization(credential: credential, oauth: oauth, store: credentialStore)
        let xrpc = XRPCClient(service: credential.session.pds, authorization: authorization)
        let spaces = SpacesClient(xrpc: xrpc)
        let space = SpaceReference(
            authority: credential.session.account, type: HummingbirdProfileSchema.spaceType,
            key: HummingbirdProfileSchema.spaceKey
        )
        self.spaces = spaces
        guard let mutationLog = changes.mutationLog else { return }
        self.appSync = AppSyncClient(
            spaces: spaces, mutationLog: mutationLog,
            repo: credential.session.account, space: space,
            appID: HummingbirdProfileSchema.appID, messaging: peerService
        )
    }

    func disconnectAccount() { appSync = nil; spaces = nil }

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
        var completedTransport = false
        if let lanSync {
            let remote = await lanSync.pull()
            do {
                try await apply(remote, needsUpload: true)
                completedTransport = true
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        guard let appSync else {
            if completedTransport { lastSyncedAt = Date(); state = .idle }
            else if case .syncing = state { state = .idle }
            return
        }
        do {
            try await ensureOwnerSpace()
            // Pull before pushing so a newer edit from another device cannot be
            // overwritten merely because this device happened to reconnect.
            let remote = try await appSync.pullMutations()
            try await apply(remote, needsUpload: false)
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
        let encoded = try JSONValue.encoding(payload)
        if let appSync { try await appSync.sendMessage(encoded, to: recipient) }
        else if let lanSync { try await lanSync.send(encoded, to: recipient) }
        else { throw PairingError.unavailable }
    }

    func peers() async throws -> [AppSyncPeerTrustSummary] {
        if let appSync { return try await appSync.peers() }
        return peerService?.peers(appIDs: [HummingbirdProfileSchema.appID]) ?? []
    }

    func verifyPeer(_ code: AppSyncPeerVerificationCode) async throws {
        if let appSync {
            _ = try await appSync.completePeerVerification(code)
        } else if let peerService {
            _ = try peerService.verifyPeer(code, appIDs: [HummingbirdProfileSchema.appID])
        } else { throw PairingError.unavailable }
    }

    func distrustPeer(_ peer: AppSyncPeer) async throws {
        if let appSync { try await appSync.distrust(peer) }
        else if let peerService { _ = try peerService.revokeTrust(with: peer) }
        else { throw PairingError.unavailable }
        // The local revocation is authoritative even while the account server
        // is unreachable. A later sync will publish it through ATProto.
        try? await appSync?.syncTrustFacts()
    }

    private func ensureOwnerSpace() async throws {
        guard let spaces else { return }
        do {
            _ = try await spaces.createOwnerSpace(
                type: HummingbirdProfileSchema.spaceType, key: HummingbirdProfileSchema.spaceKey
            )
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {
            return
        }
    }

    private func apply(_ records: [AppSyncMutation], needsUpload: Bool) async throws {
        guard let library, let plugins else { return }
        for event in records {
            guard let mutationLog = changes.mutationLog else { return }
            guard try mutationLog.merge(event, needsUpload: needsUpload) else { continue }
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
        guard let plugins, let appSync else { return }
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
