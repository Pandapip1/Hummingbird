import ATProtoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AppSyncMessage: Sendable {
    public let id: UUID
    public let payload: JSONValue
}

private enum AppSyncSchema {
    static let journal = NSID(rawValue: "com.eightybps.appsync.journal")!
    static let instance = NSID(rawValue: "com.eightybps.appsync.instance")!
    static let inbox = NSID(rawValue: "com.eightybps.appsync.inbox")!
    static let trust = NSID(rawValue: "com.eightybps.appsync.trust")!
}

private struct InstanceRecord: Codable, Sendable {
    let type = AppSyncSchema.instance.rawValue
    let registration: AppSyncInstanceRegistration
    enum CodingKeys: String, CodingKey { case type = "$type"; case registration }
}

private struct InboxRecord: Codable, Sendable {
    let type = AppSyncSchema.inbox.rawValue
    let envelope: InstanceInboxEnvelope
    enum CodingKeys: String, CodingKey { case type = "$type"; case envelope }
}

private struct TrustRecord: Codable, Sendable {
    let type = AppSyncSchema.trust.rawValue
    let fact: AppSyncTrustFact
    enum CodingKeys: String, CodingKey { case type = "$type"; case fact }
}

/// Generic offline-first replication and instance messaging within one Space.
/// Applications provide only their App ID, their Space, and opaque payloads.
public actor AppSyncClient {
    private let spaces: SpacesClient
    private let repo: DID
    private let space: SpaceReference
    private let appID: AppSyncAppID
    private let recognizedAppIDs: Set<AppSyncAppID>
    private let journalEngine: SpaceSyncEngine
    private let messaging: InstanceMessagingService?
    private let lanSync: AppSyncLANClient?
    private var localNetworkEnabled: Bool
    private var advertisement: InstanceInboxAdvertisement?
    private var cloudMessageIDs = Set<UUID>()

    public init(spaces: SpacesClient, mutationLog: AppSyncMutationLog, repo: DID,
                space: SpaceReference, appID: AppSyncAppID,
                recognizedAppIDs: Set<AppSyncAppID>? = nil,
                messaging: InstanceMessagingService?, localNetworkEnabled: Bool = false) {
        self.spaces = spaces
        self.repo = repo
        self.space = space
        self.appID = appID
        self.recognizedAppIDs = recognizedAppIDs ?? [appID]
        self.messaging = messaging
        self.localNetworkEnabled = localNetworkEnabled
        lanSync = messaging.map {
            AppSyncLANClient(messaging: $0, journal: mutationLog, appID: appID)
        }
        journalEngine = SpaceSyncEngine(
            spaces: spaces, journal: mutationLog, repo: repo, space: space,
            journalCollection: AppSyncSchema.journal
        )
    }

    /// LAN discovery and listening are opt-in because platforms may present a
    /// privacy permission prompt. Cloud synchronization does not enable them.
    public func setLocalNetworkEnabled(_ enabled: Bool) {
        localNetworkEnabled = enabled
        if !enabled {
            advertisement = nil
            messaging?.stopLANServer()
        }
    }

    public func pullMutations() async throws -> [JournalMutation] {
        try await journalEngine.pull()
    }

    /// Pulls every currently reachable trusted LAN peer. This is intentionally
    /// separate from the Space transport so callers can attempt both and retain
    /// useful progress when either network path fails.
    public func pullLANMutations() async -> [JournalMutation] {
        guard localNetworkEnabled else { return [] }
        if let messaging, advertisement == nil {
            advertisement = try? await messaging.startLANServer(appIDs: recognizedAppIDs)
        }
        return await lanSync?.pull() ?? []
    }

    public func pushMutations() async throws {
        try await journalEngine.pushPending()
    }

    public func syncMessages() async throws -> [AppSyncMessage] {
        guard let messaging else { return [] }
        try await syncTrustFacts(using: messaging)
        if localNetworkEnabled, advertisement == nil {
            advertisement = try? await messaging.startLANServer(appIDs: recognizedAppIDs)
        }
        try await publishInstance(messaging)
        var messages: [AppSyncMessage] = []
        var deliveredIDs = Set<UUID>()
        for envelope in messaging.inbox.pending()
        where envelope.appID == appID && messaging.trusts(envelope.sender) {
            deliveredIDs.insert(envelope.id)
            messages.append(.init(
                id: envelope.id,
                payload: try messaging.inbox.open(envelope, as: JSONValue.self)
            ))
        }
        var cursor: String?
        repeat {
            let page = try await spaces.listRecords(
                space: space, repo: repo, collection: AppSyncSchema.inbox, cursor: cursor
            )
            for item in page.records {
                guard let key = RecordKey(rawValue: item.rkey) else { continue }
                let value = if let listed = item.value { listed } else {
                    try await spaces.getRecord(
                        space: space, repo: repo, collection: AppSyncSchema.inbox, rkey: key
                    ).value
                }
                guard let record = try? value.decode(InboxRecord.self),
                      record.envelope.appID == appID,
                      record.envelope.recipientID == messaging.identity.publicIdentity.id,
                      messaging.trusts(record.envelope.sender) else { continue }
                try messaging.inbox.appendRemote(record.envelope)
                cloudMessageIDs.insert(record.envelope.id)
                guard deliveredIDs.insert(record.envelope.id).inserted else { continue }
                messages.append(.init(
                    id: record.envelope.id,
                    payload: try messaging.inbox.open(record.envelope, as: JSONValue.self)
                ))
            }
            cursor = page.cursor
        } while cursor != nil
        return messages
    }

    /// Replicates the complete signed fact set. Facts are immutable and keyed by
    /// event ID, so repeated/offline delivery is naturally idempotent.
    public func syncTrustFacts() async throws {
        guard let messaging else { return }
        try await syncTrustFacts(using: messaging)
    }

    /// Actionable trust choices for instances that recognize an application
    /// this client also recognizes. Callers may add LAN-discovered signed
    /// registrations; account registrations are included automatically.
    public func trustSuggestions(
        including discovered: [AppSyncInstanceRegistration] = []
    ) async throws -> [AppSyncPeerTrustSuggestion] {
        guard let messaging else { return [] }
        let registrations = try await mergedRegistrations(including: discovered)
        return messaging.trustStore.suggestions(
            among: registrations, localAppIDs: recognizedAppIDs
        )
    }

    public func peers(
        including discovered: [AppSyncInstanceRegistration] = []
    ) async throws -> [AppSyncPeerTrustSummary] {
        guard let messaging else { return [] }
        let registrations = try await mergedRegistrations(including: discovered)
        return messaging.trustStore.peers(
            among: registrations, localAppIDs: recognizedAppIDs
        )
    }

    /// Completes the verification ceremony represented by a scanned QR code.
    /// The code contains only a self-certifying signing-key digest. A peer is
    /// accepted only when a separately resolved, valid signed registration has
    /// the same digest and shares a recognized application ID.
    public func completePeerVerification(
        _ code: AppSyncPeerVerificationCode,
        including discovered: [AppSyncInstanceRegistration] = []
    ) async throws -> AppSyncPeerTrustSummary {
        guard let messaging else { throw InstanceMessagingError.credentialStoreUnavailable }
        let registrations = try await mergedRegistrations(including: discovered)
        let compatible = messaging.trustStore.peers(
            among: registrations, localAppIDs: recognizedAppIDs
        )
        guard let match = compatible.first(where: { $0.id == code.peerID }) else {
            throw AppSyncPeerVerificationError.peerNotFound
        }
        _ = try messaging.trust(match.peer)
        // Verification is a durable local action. Cloud publication is an
        // independent transport and may be unavailable while LAN sync works.
        try? await syncTrustFacts(using: messaging)
        return .init(
            registration: match.registration,
            state: messaging.trustStore.state(of: match.id)
        )
    }

    @discardableResult
    public func trust(_ peer: AppSyncPeer) throws -> AppSyncTrustFact {
        guard let messaging else { throw InstanceMessagingError.credentialStoreUnavailable }
        return try messaging.trust(peer)
    }

    @discardableResult
    public func distrust(_ peer: AppSyncPeer) throws -> AppSyncTrustFact {
        guard let messaging else { throw InstanceMessagingError.credentialStoreUnavailable }
        return try messaging.revokeTrust(with: peer)
    }

    public func acknowledgeMessage(id: UUID) async throws {
        guard let messaging else { return }
        if cloudMessageIDs.remove(id) != nil {
            try await spaces.deleteRecord(.init(
                repo: repo, space: space, collection: AppSyncSchema.inbox,
                rkey: RecordKey(rawValue: id.uuidString.lowercased())!
            ))
        }
        try messaging.inbox.deleteLocal(id: id)
    }

    public func sendMessage(_ payload: JSONValue, to recipient: InstancePublicIdentity) async throws {
        guard let messaging else { throw InstanceMessagingError.credentialStoreUnavailable }
        guard messaging.trusts(recipient) else { throw AppSyncTrustError.incompleteFact }
        let envelope = try InstanceInboxEnvelope.seal(
            payload, appID: appID, from: messaging.identity, to: recipient
        )
        if localNetworkEnabled,
           try await sendOverLANIfAvailable(envelope, recipientID: recipient.id) { return }
        _ = try await spaces.putRecord(.init(
            repo: repo, space: space, collection: AppSyncSchema.inbox,
            rkey: RecordKey(rawValue: envelope.id.uuidString.lowercased())!,
            record: try JSONValue.encoding(InboxRecord(envelope: envelope)), validate: false
        ))
    }

    private func publishInstance(_ messaging: InstanceMessagingService) async throws {
        let registration = try messaging.registration(
            appIDs: recognizedAppIDs, advertisement: advertisement
        )
        _ = try await spaces.putRecord(.init(
            repo: repo, space: space, collection: AppSyncSchema.instance,
            rkey: RecordKey(rawValue: registration.instanceID.uuidString.lowercased())!,
            record: try JSONValue.encoding(InstanceRecord(registration: registration)), validate: false
        ))
    }

    private func instanceRegistrations() async throws -> [AppSyncInstanceRegistration] {
        var registrations: [AppSyncInstanceRegistration] = []
        var cursor: String?
        repeat {
            let page = try await spaces.listRecords(
                space: space, repo: repo, collection: AppSyncSchema.instance, cursor: cursor
            )
            for item in page.records {
                let value: JSONValue
                if let listed = item.value {
                    value = listed
                } else {
                    guard let key = RecordKey(rawValue: item.rkey) else { continue }
                    value = try await spaces.getRecord(
                        space: space, repo: repo, collection: AppSyncSchema.instance, rkey: key
                    ).value
                }
                guard let record = try? value.decode(InstanceRecord.self),
                      (try? record.registration.verify()) != nil else { continue }
                registrations.append(record.registration)
            }
            cursor = page.cursor
        } while cursor != nil
        return registrations
    }

    private func mergedRegistrations(
        including discovered: [AppSyncInstanceRegistration]
    ) async throws -> [AppSyncInstanceRegistration] {
        var registrations: [AppSyncPeerID: AppSyncInstanceRegistration] = [:]
        if let messaging {
            for registration in messaging.discoveredRegistrations() {
                registrations[registration.stablePeerID] = registration
            }
        }
        for registration in discovered { registrations[registration.stablePeerID] = registration }
        // Account discovery complements LAN discovery. Losing the PDS must not
        // hide otherwise reachable local peers.
        for registration in (try? await instanceRegistrations()) ?? [] {
            registrations[registration.stablePeerID] = registration
        }
        return Array(registrations.values)
    }

    private func syncTrustFacts(using messaging: InstanceMessagingService) async throws {
        var remote: [AppSyncTrustFact] = []
        var cursor: String?
        repeat {
            let page = try await spaces.listRecords(
                space: space, repo: repo, collection: AppSyncSchema.trust, cursor: cursor
            )
            for item in page.records {
                let value: JSONValue
                if let listed = item.value {
                    value = listed
                } else {
                    guard let key = RecordKey(rawValue: item.rkey) else { continue }
                    value = try await spaces.getRecord(
                        space: space, repo: repo, collection: AppSyncSchema.trust, rkey: key
                    ).value
                }
                if let record = try? value.decode(TrustRecord.self) { remote.append(record.fact) }
            }
            cursor = page.cursor
        } while cursor != nil
        _ = try messaging.trustStore.merge(remote)
        for fact in messaging.trustStore.facts() {
            _ = try await spaces.putRecord(.init(
                repo: repo, space: space, collection: AppSyncSchema.trust,
                rkey: RecordKey(rawValue: fact.id.uuidString.lowercased())!,
                record: try JSONValue.encoding(TrustRecord(fact: fact)), validate: false
            ))
        }
    }

    private func sendOverLANIfAvailable(_ envelope: InstanceInboxEnvelope,
                                        recipientID: UUID) async throws -> Bool {
        if let registration = messaging?.discoveredRegistrations().first(where: {
            $0.instanceID == recipientID && $0.recognizes(appID)
        }), try await send(envelope, to: registration) {
            return true
        }
        let key = RecordKey(rawValue: recipientID.uuidString.lowercased())!
        guard let response = try? await spaces.getRecord(
            space: space, repo: repo, collection: AppSyncSchema.instance, rkey: key
        ), let record = try? response.value.decode(InstanceRecord.self),
              record.registration.instanceID == recipientID,
              (try? record.registration.verify()) != nil,
              record.registration.recognizes(appID) else { return false }
        return try await send(envelope, to: record.registration)
    }

    private func send(_ envelope: InstanceInboxEnvelope,
                      to registration: AppSyncInstanceRegistration) async throws -> Bool {
        guard (try? registration.verify()) != nil,
              let endpoint = registration.lanEndpoint else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 204 else { return false }
        return true
    }
}

public enum AppSyncPeerVerificationError: LocalizedError, Equatable {
    case invalidCode
    case peerNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "The peer verification code is invalid."
        case .peerNotFound:
            "No signed instance registration with a shared app ID matches this peer."
        }
    }
}
