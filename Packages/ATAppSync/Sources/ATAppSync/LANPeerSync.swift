import Foundation
import ATProtoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AppSyncLANRequest: Codable, Sendable {
    let nonce: UUID
    let appID: AppSyncAppID
}

struct AppSyncLANSnapshot: Codable, Sendable {
    let nonce: UUID
    let journal: ReplicatedJournalBatch?
    let trustFacts: [AppSyncTrustFact]
}

/// Account-independent replication over authenticated local-network peers.
/// Every request and response is signed and encrypted with instance keys; DNS-SD
/// merely discovers the endpoint and never participates in authorization.
public final class AppSyncLANClient: @unchecked Sendable {
    private let messaging: InstanceMessagingService
    private let journal: OfflineMutationJournal
    private let appID: AppSyncAppID

    public init(messaging: InstanceMessagingService, journal: OfflineMutationJournal,
                appID: AppSyncAppID) {
        self.messaging = messaging
        self.journal = journal
        self.appID = appID
        messaging.attach(journal: journal)
    }

    public func pull() async -> [JournalMutation] {
        var mutations: [JournalMutation] = []
        for registration in messaging.discoveredRegistrations()
        where registration.recognizes(appID) && messaging.trusts(registration.peer) {
            guard let snapshot = try? await snapshot(from: registration) else { continue }
            _ = try? messaging.trustStore.merge(snapshot.trustFacts)
            guard let batch = snapshot.journal,
                  let verified = try? batch.verifiedMutations() else { continue }
            mutations.append(contentsOf: verified)
        }
        return mutations
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
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw InstanceMessagingError.serverUnavailable
        }
    }

    private func snapshot(from registration: AppSyncInstanceRegistration) async throws
        -> AppSyncLANSnapshot {
        guard (try? registration.verify()) != nil,
              var endpoint = registration.lanEndpoint else {
            throw InstanceMessagingError.serverUnavailable
        }
        endpoint.deleteLastPathComponent()
        endpoint.append(path: "appsync/v1/sync")
        let nonce = UUID()
        let envelope = try InstanceInboxEnvelope.seal(
            AppSyncLANRequest(nonce: nonce, appID: appID), appID: appID,
            from: messaging.identity, to: registration.peer
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        return snapshot
    }
}
