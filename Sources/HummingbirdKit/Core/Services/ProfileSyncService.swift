import ATProtoKit
import ATAppSync
import Foundation
import Observation
import os

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
    @ObservationIgnored private let peerServiceFailure: (any Error)?
    @ObservationIgnored private var localNetworkEnabled: Bool

    init(changes: ProfileChangeStore, mutationLog: AppSyncMutationLog,
         library: LibraryStore, plugins: PluginManager,
         peerService: AppSyncPeerService?, peerServiceFailure: (any Error)? = nil,
         localNetworkEnabled: Bool = false) {
        lanSync = peerService.map {
            AppSyncLANClient(
                messaging: $0, journal: mutationLog, appID: HummingbirdProfileSchema.appID
            )
        }
        self.changes = changes
        self.library = library
        self.plugins = plugins
        self.peerService = peerService
        self.peerServiceFailure = peerServiceFailure
        self.localNetworkEnabled = localNetworkEnabled
    }

    func setLocalNetworkEnabled(_ enabled: Bool) {
        localNetworkEnabled = enabled
        Task { await appSync?.setLocalNetworkEnabled(enabled) }
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
            appID: HummingbirdProfileSchema.appID,
            messaging: peerService, messagingFailure: peerServiceFailure,
            localNetworkEnabled: localNetworkEnabled
        )
    }

    func disconnectAccount() { appSync = nil; spaces = nil }

    /// Whether profile changes sync through the signed-in account's PDS.
    var isAccountConnected: Bool { appSync != nil }

    func bootstrapCurrentProfile() {
        guard let library, let plugins else { return }
        var entities: [ProfileEntity] = []
        entities += library.subscriptions.map { .subscription($0) }
        entities += library.playlists.map { .playlist($0) }
        entities += library.watchLater.enumerated().map { .watchLater(.init(video: $1, position: $0)) }
        entities += library.history.map { .history($0) }
        entities += plugins.installed.compactMap { SyncedPlugin($0).map { .plugin($0) } }
        changes.bootstrap(entities)
    }

    func sync() async {
        guard state != .syncing else { return }
        state = .syncing
        let signposter = OSSignposter.sync
        let pass = signposter.beginInterval("SyncPass", id: signposter.makeSignpostID())
        defer { signposter.endInterval("SyncPass", pass, "\(String(describing: self.state), privacy: .private(mask: .hash))") }
        var completedTransport = false
        if localNetworkEnabled, let lanSync {
            let lanPull = signposter.beginInterval("LANPull", id: signposter.makeSignpostID())
            let remote = await lanSync.pull()
            signposter.endInterval("LANPull", lanPull, "mutations=\(remote.count)")
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
            let pdsPull = signposter.beginInterval("PDSPull", id: signposter.makeSignpostID())
            let remote = try await appSync.pullMutations()
            signposter.endInterval("PDSPull", pdsPull, "mutations=\(remote.count)")
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
        else if localNetworkEnabled, let lanSync { try await lanSync.send(encoded, to: recipient) }
        else { throw PairingError.unavailable }
    }

    func peers() async throws -> [AppSyncPeerTrustSummary] {
        if let appSync { return try await appSync.peers() }
        guard let peerService else { return [] }
        return await PeerTrust.peers(peerService)
    }

    func verifyPeer(_ code: AppSyncPeerVerificationCode) async throws {
        if let appSync {
            _ = try await appSync.completePeerVerification(code)
        } else if let peerService {
            try await PeerTrust.verify(code, with: peerService)
        } else { throw PairingError.unavailable }
    }

    func distrustPeer(_ peer: AppSyncPeer) async throws {
        if let appSync { try await appSync.distrust(peer) }
        else if let peerService { try await PeerTrust.revoke(peer, with: peerService) }
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
        guard let mutationLog = changes.mutationLog, !records.isEmpty else { return }
        // Merging rewrites the journal file, so it happens once per pull and
        // away from the main actor; only the winning changes come back here.
        let merged = try await Self.merge(records, into: mutationLog, needsUpload: needsUpload)
        guard let library, let plugins else { return }
        var decodeFailure: (any Error)?
        for event in merged {
            if event.operation == .delete {
                if event.collection == HummingbirdProfileSchema.plugin {
                    plugins.applyRemoteDelete(key: event.recordKey)
                } else {
                    library.applyRemoteDelete(collection: event.collection, key: event.recordKey)
                }
                continue
            }
            guard let payload = event.value else { continue }
            let entity: ProfileEntity?
            do { entity = try ProfileEntity.decode(collection: event.collection, payload: payload) }
            catch {
                // One unreadable record does not hold back the rest; the
                // pass still reports it.
                decodeFailure = decodeFailure ?? error
                continue
            }
            switch entity {
            case .plugin(let plugin): try await plugins.applyRemote(plugin)
            case let entity?: library.applyRemote(entity, deleted: false)
            case nil: break
            }
        }
        if let decodeFailure { throw decodeFailure }
    }

    @concurrent
    private static func merge(_ records: [AppSyncMutation], into mutationLog: AppSyncMutationLog,
                              needsUpload: Bool) async throws -> [AppSyncMutation] {
        try mutationLog.merge(records, needsUpload: needsUpload)
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

/// Peer-trust reads and writes verify signatures and rewrite the trust file,
/// so they run away from the main actor.
enum PeerTrust {
    @concurrent
    static func peers(_ service: AppSyncPeerService) async -> [AppSyncPeerTrustSummary] {
        service.peers(appIDs: [HummingbirdProfileSchema.appID])
    }

    @concurrent
    static func verify(_ code: AppSyncPeerVerificationCode, with service: AppSyncPeerService) async throws {
        _ = try service.verifyPeer(code, appIDs: [HummingbirdProfileSchema.appID])
    }

    @concurrent
    static func revoke(_ peer: AppSyncPeer, with service: AppSyncPeerService) async throws {
        _ = try service.revokeTrust(with: peer)
    }
}
