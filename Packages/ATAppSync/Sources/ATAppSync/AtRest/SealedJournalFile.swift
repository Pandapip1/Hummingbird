import Foundation
import PlatformSupport

/// The journal on disk: every event (and the outbox) sealed one by one, and
/// the rest of the state (clock, versions, tombstones, cursors) sealed as
/// one record. Nothing in it is readable without the profile's key.
///
/// Reading is salvaging: a journal from before sealing is taken as is (and
/// sealed by the caller); a record that doesn't open is quarantined and the
/// rest is kept. A damaged state record leaves the events, with a clock
/// moved past every one of them.
enum SealedJournalFile {
    /// The profile's key can't be read now: the journal is neither damaged
    /// nor empty, and opening it is tried again later.
    struct KeyUnavailable: Error {}

    struct Stored: Codable {
        var format: Int
        var meta: Data
        var events: [Data]
        var pending: [Data]
    }

    static let format = 1

    static func write(_ snapshot: JournalSnapshot, sealer: AtRestSealer, to url: URL) throws {
        let encoded = try JSONEncoder().encode(snapshot)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.fileWriteUnknown)
        }
        let events = try seal(object["events"], sealer: sealer, context: "event")
        let pending = try seal(object["pending"], sealer: sealer, context: "pending")
        object["events"] = nil
        object["pending"] = nil
        let meta = try sealer.seal(try JSONSerialization.data(withJSONObject: object), context: "meta")
        let stored = Stored(format: format, meta: meta, events: events, pending: pending)
        try JSONEncoder().encode(stored).write(to: url, options: [.atomic])
        // Readable while locked after the first unlock: background sync
        // reads and writes it then. The seal is what keeps it private.
        try FileProtection.set(.completeUntilFirstUserAuthentication, for: url)
    }

    static func read(_ data: Data, sealer: AtRestSealer, file: URL,
                     deviceID: UUID) throws -> (snapshot: JournalSnapshot, needsReseal: Bool) {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // Written before sealing: read as it was, sealed on the way out.
            return (try JSONDecoder().decode(JournalSnapshot.self, from: data), true)
        }
        var needsReseal = false
        var object: [String: Any]
        switch sealer.open(stored.meta, context: "meta") {
        case .opened(let meta), .legacyPlaintext(let meta):
            object = (try? JSONSerialization.jsonObject(with: meta) as? [String: Any]) ?? [:]
            if object.isEmpty {
                AtRestQuarantine.keep(stored.meta, label: "meta", near: file)
                needsReseal = true
            }
        case .damaged:
            AtRestQuarantine.keep(stored.meta, label: "meta", near: file)
            object = [:]
            needsReseal = true
        case .unavailable:
            throw KeyUnavailable()
        }
        if object["clock"] == nil {
            object["clock"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(HybridLogicalClock(deviceID: deviceID))
            )
        }
        var opened = try open(stored.events, sealer: sealer, context: "event", file: file)
        object["events"] = opened.values
        needsReseal = needsReseal || opened.needsReseal
        opened = try open(stored.pending, sealer: sealer, context: "pending", file: file)
        object["pending"] = opened.values
        needsReseal = needsReseal || opened.needsReseal
        var snapshot = try JSONDecoder().decode(JournalSnapshot.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        // After losing the state record, the clock must still run ahead of
        // every event kept.
        for event in snapshot.events { snapshot.clock.observe(event.timestamp) }
        return (snapshot, needsReseal)
    }

    private static func seal(_ value: Any?, sealer: AtRestSealer, context: String) throws -> [Data] {
        guard let items = value as? [Any] else { return [] }
        return try items.map { item in
            try sealer.seal(try JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed]),
                            context: context)
        }
    }

    private static func open(_ sealed: [Data], sealer: AtRestSealer, context: String,
                             file: URL) throws -> (values: [Any], needsReseal: Bool) {
        var values: [Any] = []
        var needsReseal = false
        for item in sealed {
            let content = sealer.open(item, context: context)
            switch content {
            case .opened(let data), .legacyPlaintext(let data):
                if case .legacyPlaintext = content { needsReseal = true }
                if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    values.append(value)
                } else {
                    AtRestQuarantine.keep(item, label: context, near: file)
                    needsReseal = true
                }
            case .damaged:
                AtRestQuarantine.keep(item, label: context, near: file)
                needsReseal = true
            case .unavailable:
                throw KeyUnavailable()
            }
        }
        return (values, needsReseal)
    }
}
