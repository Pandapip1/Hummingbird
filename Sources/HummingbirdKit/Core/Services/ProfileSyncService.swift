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
    /// Problems from the last pass that did not stop it, one line each:
    /// devices that didn't answer, records that couldn't be read, sources
    /// that couldn't be installed. Each is retried on the next pass.
    private(set) var issues: [String] = []

    @ObservationIgnored private var appSync: AppSyncClient?
    @ObservationIgnored private var spaces: SpacesClient?
    @ObservationIgnored private let lanSync: AppSyncLANClient?
    @ObservationIgnored private let changes: ProfileChangeStore
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var plugins: PluginManager?
    @ObservationIgnored private let peerService: AppSyncPeerService?
    @ObservationIgnored private let peerServiceFailure: (any Error)?
    @ObservationIgnored private var localNetworkEnabled: Bool
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var passRequested = false

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

    /// Runs a sync pass. A call while a pass is running asks for one more
    /// pass after it (changes made meanwhile are not left for the timer)
    /// and returns when that one has finished.
    func sync() async {
        if let running {
            passRequested = true
            await running.value
            return
        }
        let passes = Task { [weak self] in
            guard let self else { return }
            repeat {
                passRequested = false
                await pass()
            } while passRequested
        }
        running = passes
        await passes.value
        running = nil
    }

    /// One pass. The local network and the account's PDS are pulled at the
    /// same time, each merging what it got into the journal; then whatever
    /// the journal holds that this device hasn't applied is applied in one
    /// batch. Merging is order independent, so the result doesn't depend
    /// on which transport (or peer) answered first.
    private func pass() async {
        state = .syncing
        let signposter = OSSignposter.sync
        let pass = signposter.beginInterval("SyncPass", id: signposter.makeSignpostID())
        defer { signposter.endInterval("SyncPass", pass, "\(String(describing: self.state), privacy: .private(mask: .hash))") }

        async let lanOutcome = pullLocalNetwork()
        async let accountOutcome = syncAccount()
        let transports = [await lanOutcome, await accountOutcome].compactMap { $0 }

        let applyIssues = await applyUnapplied()
        var problems = transports.flatMap(\.issues)
        if transports.contains(where: \.succeeded) {
            // One transport worked; the other's failure is still worth saying.
            for case let failure? in transports.map(\.failure) {
                switch failure {
                case .offline: problems.append("Offline — account changes are queued.")
                case .failed(let message): problems.append(message)
                case .idle, .syncing: break
                }
            }
        }
        issues = problems + applyIssues

        if transports.contains(where: \.succeeded) {
            lastSyncedAt = Date()
            state = .idle
        } else if let failure = transports.compactMap(\.failure).first {
            state = failure
        } else {
            state = .idle
        }
    }

    private struct TransportOutcome {
        var succeeded = false
        var failure: State?
        var issues: [String] = []
    }

    /// Pulls every reachable trusted device at once (see AppSyncLANClient).
    /// Nil when local network sync is off.
    private func pullLocalNetwork() async -> TransportOutcome? {
        guard localNetworkEnabled, let lanSync else { return nil }
        let signposter = OSSignposter.sync
        let interval = signposter.beginInterval("LANPull", id: signposter.makeSignpostID())
        let report = await lanSync.pullAndMerge(needsUpload: true)
        signposter.endInterval("LANPull", interval, "peers=\(report.peersAsked) merged=\(report.merged.count) failed=\(report.failures.count)")
        var outcome = TransportOutcome()
        if let mergeFailure = report.mergeFailure {
            outcome.failure = .failed("Changes from your other devices couldn’t be saved: \(mergeFailure)")
            return outcome
        }
        let answered = report.peersAsked - report.failures.count
        outcome.succeeded = answered > 0
        if report.peersAsked == 0 {
            // Without an account this is the only transport, so say so
            // instead of claiming to be synced.
            if appSync == nil { outcome.issues.append("No trusted devices are reachable on the local network.") }
        } else if !report.failures.isEmpty {
            let reason = report.failures.values.sorted().first ?? ""
            outcome.issues.append(report.failures.count == report.peersAsked
                ? "Your other devices didn’t answer: \(reason)"
                : "\(report.failures.count) of \(report.peersAsked) devices didn’t answer: \(reason)")
            if answered == 0 { outcome.failure = .failed("Couldn’t reach your other devices: \(reason)") }
        }
        return outcome
    }

    /// Pull, push and messages through the account's PDS. Nil without an
    /// account. Pull still precedes push within this transport, so a newer
    /// edit from another device is never overwritten merely because this
    /// device reconnected.
    private func syncAccount() async -> TransportOutcome? {
        guard let appSync, let mutationLog = changes.mutationLog else { return nil }
        var outcome = TransportOutcome()
        do {
            try await ensureOwnerSpace()
            let signposter = OSSignposter.sync
            let pdsPull = signposter.beginInterval("PDSPull", id: signposter.makeSignpostID())
            let remote = try await appSync.pullMutations()
            signposter.endInterval("PDSPull", pdsPull, "mutations=\(remote.count)")
            try await Self.merge(remote, into: mutationLog, needsUpload: false)
            try await appSync.pushMutations()
            let messages = try await appSync.syncMessages()
            try await applyMessages(messages, appSync: appSync)
            outcome.succeeded = true
        } catch let error as URLError where [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .timedOut,
        ].contains(error.code) {
            outcome.failure = .offline
        } catch {
            outcome.failure = .failed(error.localizedDescription)
        }
        return outcome
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

    /// Applies every record whose winner this device hasn't applied: newly
    /// merged ones, ones a previous pass couldn't apply, and, once, all of a
    /// journal written before applying was tracked (devices that lost
    /// records to the old abort-on-first-failure apply get them back).
    /// Decoding and computing the new collections happen away from the main
    /// actor; the library gets one assignment and one save per changed
    /// collection, and plugins install concurrently and land in one batch.
    /// Only what was applied is recorded as applied; the rest is retried.
    /// Returns problems to show.
    private func applyUnapplied() async -> [String] {
        guard let mutationLog = changes.mutationLog, let library, let plugins else { return [] }
        let records = await Self.decodeUnapplied(in: mutationLog)
        guard !records.isEmpty else { return [] }

        async let pluginKeys = plugins.applySynced(records.plugins.map(\.change))

        var appliedLibrary: [JournalMutation] = []
        var remaining = records.library
        // A collection edited here while its new value was computed is
        // computed again from the edited state.
        for _ in 0..<3 where !remaining.isEmpty {
            let batch = await LibrarySyncBatch.compute(from: library.syncBase(), changes: remaining)
            let committed = library.commit(batch)
            appliedLibrary += remaining.filter { committed.contains($0.mutation.collection) }.map(\.mutation)
            remaining.removeAll { committed.contains($0.mutation.collection) }
        }

        let installedKeys = await pluginKeys
        let appliedPlugins = records.plugins.filter { installedKeys.contains($0.change.key) }.map(\.mutation)
        var problems: [String] = []
        do {
            try await Self.markApplied(appliedLibrary + appliedPlugins, in: mutationLog)
        } catch {
            problems.append("This device couldn’t record what it synced: \(error.localizedDescription)")
        }
        if !records.undecodable.isEmpty {
            problems.append(records.undecodable.count == 1
                ? "1 synced item couldn’t be read. Updating Hummingbird may fix this."
                : "\(records.undecodable.count) synced items couldn’t be read. Updating Hummingbird may fix this.")
        }
        for install in plugins.syncInstalls.values.sorted(by: { $0.displayName < $1.displayName }) {
            if let failure = install.failure {
                problems.append("\(install.displayName) couldn’t be installed: \(failure) It will be retried.")
            }
        }
        return problems
    }

    /// Unapplied winners, decoded and sorted by destination.
    struct UnappliedRecords: Sendable {
        var library: [LibrarySyncChange] = []
        var plugins: [(mutation: JournalMutation, change: PluginSyncChange)] = []
        var undecodable: [JournalMutation] = []
        var isEmpty: Bool { library.isEmpty && plugins.isEmpty && undecodable.isEmpty }
    }

    @concurrent
    private static func decodeUnapplied(in mutationLog: AppSyncMutationLog) async -> UnappliedRecords {
        var records = UnappliedRecords()
        for mutation in mutationLog.unappliedWinners() {
            let entity: ProfileEntity?
            if mutation.operation == .delete {
                entity = nil
            } else {
                do {
                    guard let payload = mutation.value,
                          let decoded = try ProfileEntity.decode(collection: mutation.collection, payload: payload)
                    else {
                        // A collection this version doesn't know: left for a
                        // version that does.
                        continue
                    }
                    entity = decoded
                } catch {
                    records.undecodable.append(mutation)
                    continue
                }
            }
            if mutation.collection == HummingbirdProfileSchema.plugin {
                var plugin: SyncedPlugin?
                if case .plugin(let value)? = entity { plugin = value }
                records.plugins.append((mutation, PluginSyncChange(key: mutation.recordKey, plugin: plugin)))
            } else if ProfileEntity.libraryCollections.contains(mutation.collection) {
                records.library.append(LibrarySyncChange(mutation: mutation, entity: entity))
            }
        }
        return records
    }

    @concurrent
    private static func markApplied(_ mutations: [JournalMutation], in mutationLog: AppSyncMutationLog) async throws {
        guard !mutations.isEmpty else { return }
        try mutationLog.markApplied(mutations)
    }

    @concurrent
    private static func merge(_ records: [AppSyncMutation], into mutationLog: AppSyncMutationLog,
                              needsUpload: Bool) async throws {
        guard !records.isEmpty else { return }
        try mutationLog.merge(records, needsUpload: needsUpload)
    }

    /// Credential transfers: each is stored, then all are acknowledged at once.
    private func applyMessages(_ messages: [AppSyncMessage], appSync: AppSyncClient) async throws {
        guard let plugins else { return }
        var accepted: [UUID] = []
        for message in messages {
            guard case .credentials(let transfer) = try message.payload.decode(PairingPayload.self),
                  !transfer.auth.isEmpty,
                  plugins.plugin(transfer.pluginID)?.config.sourceUrl == transfer.pluginSourceURL.absoluteString
            else { continue }
            plugins.saveAuth(transfer.auth, pluginID: transfer.pluginID)
            accepted.append(message.id)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in accepted { group.addTask { try await appSync.acknowledgeMessage(id: id) } }
            try await group.waitForAll()
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
