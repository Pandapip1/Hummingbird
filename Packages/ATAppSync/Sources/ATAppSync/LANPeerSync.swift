import Foundation
import ATProtoKit
import os
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AppSyncLANRequest: Codable, Sendable {
    let nonce: UUID
    let appID: AppSyncAppID
    /// Where this reader got up to in the responder's journal. Absent (and
    /// ignored by older responders) means "send everything".
    var since: JournalCursor? = nil
}

struct AppSyncLANSnapshot: Codable, Sendable {
    let nonce: UUID
    let journal: ReplicatedJournalBatch?
    let trustFacts: [AppSyncTrustFact]
    /// Where the reader should ask from next time. Older responders omit it.
    var cursor: JournalCursor? = nil
}

/// The outcome of one pull from every reachable trusted peer.
public struct AppSyncLANPullReport: Sendable {
    /// Trusted peers that were asked.
    public var peersAsked = 0
    /// Events that changed a record's winner in the local journal.
    public var merged: [JournalMutation] = []
    /// Peers that did not answer usefully, with why.
    public var failures: [AppSyncPeer: String] = [:]
    /// Set when what peers sent could not be written to the local journal;
    /// nothing from this pull was kept, and the next pull asks again.
    public var mergeFailure: String?

    public init() {}
}

/// Account-independent replication over authenticated local-network peers.
/// Every request and response is signed and encrypted with instance keys; DNS-SD
/// merely discovers the endpoint and never participates in authorization.
public final class AppSyncLANClient: Sendable {
    /// How many peers are asked at once. A pull asks each trusted peer once,
    /// so this only matters with many instances; it bounds open connections
    /// and the snapshots held in memory together.
    public static let maximumConcurrentPeers = 6
    /// How long one peer may take to answer. An instance that went to
    /// sleep or left the network never holds back the others.
    public static let peerTimeout: TimeInterval = 20

    private let messaging: InstanceMessagingService
    private let journal: OfflineMutationJournal
    private let appID: AppSyncAppID

    /// Per peer, where this instance got up to in that peer's journal. Kept
    /// in memory: the first pull after launch reads everything, later ones
    /// only what arrived since.
    private let cursors = Mutex<[AppSyncPeerID: JournalCursor]>([:])

    public init(messaging: InstanceMessagingService, journal: OfflineMutationJournal,
                appID: AppSyncAppID) {
        self.messaging = messaging
        self.journal = journal
        self.appID = appID
        messaging.attach(journal: journal)
    }

    /// Every trusted peer's events, without merging them anywhere.
    public func pull() async -> [JournalMutation] {
        await fetchAll(incremental: false).flatMap { $0.result.events ?? [] }
    }

    /// Pulls every reachable trusted peer concurrently and merges what they
    /// sent into this client's journal in one durable write. A peer's
    /// cursor only moves once its events are in the journal, so nothing a
    /// failed write dropped is skipped next time. Merging is order
    /// independent, so the result does not depend on which peer answers first.
    public func pullAndMerge(needsUpload: Bool = true) async -> AppSyncLANPullReport {
        let fetched = await fetchAll(incremental: true)
        var report = AppSyncLANPullReport()
        report.peersAsked = fetched.count
        var events: [JournalMutation] = []
        var advanced: [AppSyncPeerID: JournalCursor] = [:]
        for peer in fetched {
            switch peer.result {
            case .failure(let message): report.failures[peer.peer] = message
            case .success(let pulled, let cursor):
                events += pulled
                if let cursor { advanced[peer.peer.stableID] = cursor }
            }
        }
        do {
            report.merged = try await Self.merge(events, into: journal, needsUpload: needsUpload)
            cursors.withLock { $0.merge(advanced) { $1 } }
        } catch {
            report.mergeFailure = error.localizedDescription
        }
        return report
    }

    @concurrent
    private static func merge(_ events: [JournalMutation], into journal: OfflineMutationJournal,
                              needsUpload: Bool) async throws -> [JournalMutation] {
        guard !events.isEmpty else { return [] }
        return try journal.merge(events, needsUpload: needsUpload)
    }

    private enum PeerResult: Sendable {
        case success([JournalMutation], JournalCursor?)
        case failure(String)

        var events: [JournalMutation]? {
            if case .success(let events, _) = self { events } else { nil }
        }
    }

    private func fetchAll(incremental: Bool) async -> [(peer: AppSyncPeer, result: PeerResult)] {
        let registrations = messaging.discoveredRegistrations().filter {
            $0.recognizes(appID) && messaging.trusts($0.peer)
        }
        let known: [AppSyncPeerID: JournalCursor] = incremental ? cursors.withLock({ $0 }) : [:]
        return await withTaskGroup(of: (AppSyncPeer, PeerResult).self) { group in
            var results: [(peer: AppSyncPeer, result: PeerResult)] = []
            var pending = registrations[...]
            var running = 0
            while let registration = pending.popFirst() {
                // At the limit, ask the next peer only when one has answered.
                if running == Self.maximumConcurrentPeers, let finished = await group.next() {
                    results.append(finished)
                    running -= 1
                }
                let since = known[registration.peer.stableID]
                group.addTask { [self] in (registration.peer, await fetch(from: registration, since: since)) }
                running += 1
            }
            for await finished in group { results.append(finished) }
            return results
        }
    }

    /// One peer's snapshot, verified. Runs concurrently with the others, so
    /// signature checks for several peers happen at once.
    private func fetch(from registration: AppSyncInstanceRegistration,
                       since: JournalCursor?) async -> PeerResult {
        do {
            let snapshot = try await snapshot(from: registration, since: since)
            _ = try? messaging.trustStore.merge(snapshot.trustFacts)
            guard let batch = snapshot.journal else { return .success([], snapshot.cursor) }
            return .success(try batch.verifiedMutations(), snapshot.cursor)
        } catch {
            AppSyncDiagnostics.lan.notice("lan_pull_failed error=\(String(describing: error), privacy: .private(mask: .hash))")
            return .failure(error.localizedDescription)
        }
    }

    public func send(_ payload: JSONValue, to recipient: AppSyncPeer) async throws {
        guard messaging.trusts(recipient),
              let registration = messaging.discoveredRegistrations().first(where: {
                $0.peer == recipient && $0.recognizes(appID)
              }), let endpoint = registration.lanEndpoint else {
            throw InstanceMessagingError.serverUnavailable
        }
        let envelope = try InstanceInboxEnvelope.seal(
            payload, appID: appID, from: messaging.identity, to: recipient
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.peerTimeout
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw InstanceMessagingError.serverUnavailable
        }
    }

    private func snapshot(from registration: AppSyncInstanceRegistration,
                          since: JournalCursor?) async throws -> AppSyncLANSnapshot {
        guard (try? registration.verify()) != nil,
              var endpoint = registration.lanEndpoint else {
            throw InstanceMessagingError.serverUnavailable
        }
        endpoint.deleteLastPathComponent()
        endpoint.append(path: "appsync/v1/sync")
        let signposter = AppSyncDiagnostics.lanSignposter
        let signpost = signposter.beginInterval("LANRequest", id: signposter.makeSignpostID(), "path=sync")
        var outcome = "failed"
        defer { signposter.endInterval("LANRequest", signpost, "\(outcome, privacy: .public)") }
        let nonce = UUID()
        let envelope = try InstanceInboxEnvelope.seal(
            AppSyncLANRequest(nonce: nonce, appID: appID, since: since), appID: appID,
            from: messaging.identity, to: registration.peer
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.peerTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstanceMessagingError.serverUnavailable
        }
        let sealed = try JSONDecoder().decode(InstanceInboxEnvelope.self, from: data)
        guard sealed.sender == registration.peer, sealed.appID == appID else {
            throw InstanceMessagingError.invalidSignature
        }
        let snapshot = try messaging.inbox.open(sealed, as: AppSyncLANSnapshot.self)
        guard snapshot.nonce == nonce else { throw InstanceMessagingError.conflictingReplay }
        outcome = "ok"
        return snapshot
    }
}

/// The path cache-sync requests are posted to.
enum CacheSyncRoute {
    static let path = "/appsync/v1/cache"
}

/// The outcome of one cache pull.
public struct AppSyncCachePullReport: Sendable {
    public var peersAsked = 0
    /// Records taken in.
    public var received = 0
    /// Whether a peer's newer key epoch was adopted (the cache then re-keys
    /// in the background).
    public var adoptedEpoch = false
    public var failures = 0

    public init() {}
}

extension AppSyncLANClient {
    /// Refills `cache` from every reachable trusted peer: follows the
    /// trusted set (rotating the key epoch if a device left it), then per
    /// peer asks for its manifest and fetches only what this device lacks.
    /// A peer on another epoch hands over its keys if it wins; one on an
    /// older epoch catches up at its own next pull. `accounts` are the
    /// accounts this device is signed in with, to recognise their hashes.
    public func pullCache(into cache: CacheJournal, accounts: [String]) async -> AppSyncCachePullReport {
        var report = AppSyncCachePullReport()
        let trusted = messaging.trustedPeers()
        do { try cache.follow(trusted: trusted) } catch {
            report.failures += 1
            return report
        }
        let registrations = messaging.discoveredRegistrations().filter {
            $0.recognizes(appID) && messaging.trusts($0.peer)
        }
        for registration in registrations {
            guard !Task.isCancelled else { break }
            report.peersAsked += 1
            do {
                var response = try await cacheRequest(.manifest, epoch: cache.epoch, to: registration)
                if let offer = response.offer {
                    if try cache.consider(offer, trusted: trusted) {
                        report.adoptedEpoch = true
                        response = try await cacheRequest(.manifest, epoch: cache.epoch, to: registration)
                    } else {
                        continue
                    }
                }
                guard let manifest = response.manifest else { continue }
                let want = try cache.want(from: manifest)
                guard !want.isEmpty else { continue }
                let fetched = try await cacheRequest(.fetch(want), epoch: cache.epoch, to: registration)
                guard let transfer = fetched.transfer else { continue }
                report.received += try cache.apply(transfer, accounts: accounts)
            } catch {
                report.failures += 1
                AppSyncDiagnostics.lan.notice("lan_cache_pull_failed error=\(String(describing: error), privacy: .private(mask: .hash))")
            }
        }
        cache.persist()
        return report
    }

    private func cacheRequest(_ step: CacheSyncRequest.Step, epoch: CacheEpochID?,
                              to registration: AppSyncInstanceRegistration) async throws -> CacheSyncResponse {
        guard (try? registration.verify()) != nil, var endpoint = registration.lanEndpoint else {
            throw InstanceMessagingError.serverUnavailable
        }
        endpoint.deleteLastPathComponent()
        endpoint.append(path: String(CacheSyncRoute.path.dropFirst()))
        let nonce = UUID()
        var payload = CacheSyncRequest(nonce: nonce, appID: appID, epoch: epoch, step: step)
        try payload.pad()
        let envelope = try InstanceInboxEnvelope.seal(payload, appID: appID, from: messaging.identity,
                                                      to: registration.peer)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.peerTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstanceMessagingError.serverUnavailable
        }
        let sealed = try JSONDecoder().decode(InstanceInboxEnvelope.self, from: data)
        guard sealed.sender == registration.peer, sealed.appID == appID else {
            throw InstanceMessagingError.invalidSignature
        }
        let opened = try messaging.inbox.open(sealed, as: CacheSyncResponse.self)
        guard opened.nonce == nonce else { throw InstanceMessagingError.conflictingReplay }
        return opened
    }
}
