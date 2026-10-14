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
    private var advertisement: InstanceInboxAdvertisement?
    private var cloudMessageIDs = Set<UUID>()

    public init(spaces: SpacesClient, mutationLog: AppSyncMutationLog, repo: DID,
                space: SpaceReference, appID: AppSyncAppID,
                recognizedAppIDs: Set<AppSyncAppID>? = nil,
                messaging: InstanceMessagingService?) {
        self.spaces = spaces
        self.repo = repo
        self.space = space
        self.appID = appID
        self.recognizedAppIDs = recognizedAppIDs ?? [appID]
        self.messaging = messaging
        journalEngine = SpaceSyncEngine(
            spaces: spaces, journal: mutationLog, repo: repo, space: space,
            journalCollection: AppSyncSchema.journal
        )
    }

    public func pullMutations() async throws -> [JournalMutation] {
        try await journalEngine.pull()
    }

    public func pushMutations() async throws {
        try await journalEngine.pushPending()
    }

    public func syncMessages() async throws -> [AppSyncMessage] {
        guard let messaging else { return [] }
        if advertisement == nil { advertisement = try? await messaging.startLANServer() }
        try await publishInstance(messaging)
        var messages: [AppSyncMessage] = []
        var deliveredIDs = Set<UUID>()
        for envelope in messaging.inbox.pending() where envelope.appID == appID {
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
                      record.envelope.recipientID == messaging.identity.publicIdentity.id else { continue }
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
        let envelope = try InstanceInboxEnvelope.seal(
            payload, appID: appID, from: messaging.identity, to: recipient
        )
        if try await sendOverLANIfAvailable(envelope, recipientID: recipient.id) { return }
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

    private func sendOverLANIfAvailable(_ envelope: InstanceInboxEnvelope,
                                        recipientID: UUID) async throws -> Bool {
        let key = RecordKey(rawValue: recipientID.uuidString.lowercased())!
        guard let response = try? await spaces.getRecord(
            space: space, repo: repo, collection: AppSyncSchema.instance, rkey: key
        ), let record = try? response.value.decode(InstanceRecord.self),
              record.registration.instanceID == recipientID,
              (try? record.registration.verify()) != nil,
              record.registration.recognizes(appID),
              let endpoint = record.registration.lanEndpoint,
              let capability = record.registration.lanAppendCapability else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(capability.base64URL)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 204 else { return false }
        return true
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
