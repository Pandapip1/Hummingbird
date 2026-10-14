import Foundation
import ATProtoKit

public struct ReplicatedJournalEvent: Codable, Hashable, Sendable {
    public let type: String
    public let eventID: UUID
    public let collection: NSID
    public let recordKey: RecordKey
    public let operation: JournalMutation.Operation
    public let payload: JSONValue?
    public let timestamp: HybridLogicalTimestamp

    public init(type: NSID, mutation: JournalMutation) {
        self.type = type.rawValue
        eventID = mutation.id
        collection = mutation.collection
        recordKey = mutation.recordKey
        operation = mutation.operation
        payload = mutation.value
        timestamp = mutation.timestamp
    }

    public var mutation: JournalMutation {
        .init(id: eventID, collection: collection, recordKey: recordKey,
              operation: operation, value: payload, timestamp: timestamp)
    }

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case eventID, collection, recordKey, operation, payload, timestamp
    }
}

/// Offline-first replication for a single user's repository in a Space.
/// Network failure is a normal outcome: acknowledged operations are removed,
/// while failed and subsequent operations remain durably queued for retry.
public actor SpaceSyncEngine {
    private let spaces: SpacesClient
    private let journal: OfflineMutationJournal
    private let repo: DID
    private let space: SpaceReference
    private let journalCollection: NSID

    public init(spaces: SpacesClient, journal: OfflineMutationJournal, repo: DID,
                space: SpaceReference, journalCollection: NSID) {
        self.spaces = spaces
        self.journal = journal
        self.repo = repo
        self.space = space
        self.journalCollection = journalCollection
    }

    @discardableResult
    public func enqueuePut(collection: NSID, key: RecordKey, payload: JSONValue) async throws -> JournalMutation {
        try journal.appendPut(collection: collection, key: key, value: payload)
    }

    @discardableResult
    public func enqueueDelete(collection: NSID, key: RecordKey) async throws -> JournalMutation {
        try journal.appendDelete(collection: collection, key: key)
    }

    public func pushPending() async throws {
        let mutations = journal.pending()
        guard !mutations.isEmpty else { return }
        // A batch is a signed checkpoint. Including the entire known event set
        // lets a later checkpoint safely subsume this one.
        let batch = try journal.signedBatch(type: journalCollection, mutations: journal.events())
        let value = try JSONValue.encoding(batch)
        _ = try await spaces.putRecord(.init(
            repo: repo, space: space, collection: journalCollection,
            rkey: RecordKey(rawValue: batch.batchID.uuidString.lowercased())!, record: value,
            // App lexicons can be prototyped before their authority record
            // is published. The batch is cryptographically verified locally.
            validate: false
        ))
        try journal.acknowledge(Set(mutations.map(\.id)))
        await compactBatches(coveredBy: batch)
    }

    public func pull() async throws -> [JournalMutation] {
        var result: [JournalMutation] = []
        var cursor: String?
        repeat {
            let page = try await spaces.listRecords(
                space: space, repo: repo, collection: journalCollection, cursor: cursor
            )
            for item in page.records {
                guard let key = RecordKey(rawValue: item.rkey) else { continue }
                let value: JSONValue
                if let listed = item.value { value = listed }
                else {
                    value = try await spaces.getRecord(
                        space: space, repo: repo, collection: journalCollection, rkey: key
                    ).value
                }
                if let batch = try? value.decode(ReplicatedJournalBatch.self),
                   batch.type == journalCollection.rawValue {
                    // A malformed or forged batch invalidates the entire record;
                    // never apply a verified prefix of a submitted transaction.
                    result.append(contentsOf: try batch.verifiedMutations())
                } else if let event = try? value.decode(ReplicatedJournalEvent.self),
                          event.type == journalCollection.rawValue {
                    // Read compatibility for records created before signed batches.
                    result.append(event.mutation)
                }
            }
            cursor = page.cursor
        } while cursor != nil
        return result
    }

    private func compactBatches(coveredBy newest: ReplicatedJournalBatch) async {
        guard let newestEntries = try? newest.verifiedEntries() else { return }
        var cursor: String?
        repeat {
            guard let page = try? await spaces.listRecords(
                space: space, repo: repo, collection: journalCollection, cursor: cursor
            ) else { return }
            for item in page.records where item.rkey != newest.batchID.uuidString.lowercased() {
                guard let key = RecordKey(rawValue: item.rkey) else { continue }
                let value: JSONValue
                if let listed = item.value { value = listed }
                else if let fetched = try? await spaces.getRecord(
                    space: space, repo: repo, collection: journalCollection, rkey: key
                ) { value = fetched.value }
                else { continue }
                guard let older = try? value.decode(ReplicatedJournalBatch.self),
                      older.type == journalCollection.rawValue,
                      older.originInstanceID == newest.originInstanceID,
                      older.originSigningKey == newest.originSigningKey,
                      let olderEntries = try? older.verifiedEntries(),
                      olderEntries.allSatisfy({ newestEntries[$0.key] == $0.value }) else { continue }
                try? await spaces.deleteRecord(.init(
                    repo: repo, space: space, collection: journalCollection, rkey: key
                ))
            }
            cursor = page.cursor
        } while cursor != nil
    }
}
