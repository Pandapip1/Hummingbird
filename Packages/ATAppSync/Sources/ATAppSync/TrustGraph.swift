import Crypto
import Foundation

/// A self-certifying instance identifier derived solely from its durable
/// signing key. Encryption keys may rotate without changing this identity.
public struct AppSyncPeerID: RawRepresentable, Codable, Hashable, Comparable, Sendable,
    CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 64, rawValue.allSatisfy(\.isHexDigit) else { return nil }
        self.rawValue = rawValue.lowercased()
    }

    public init(signingKey: Data) {
        rawValue = SHA256.hash(data: signingKey).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AppSyncTrustVersion: Codable, Hashable, Comparable, Sendable {
    public let timestamp: HybridLogicalTimestamp
    public let eventID: UUID

    public init(timestamp: HybridLogicalTimestamp, eventID: UUID = UUID()) {
        self.timestamp = timestamp; self.eventID = eventID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.eventID.uuidString < rhs.eventID.uuidString
    }
}

/// A directed, append-only statement. Trust affects only issuer → subject.
/// Distrust ends both directions for observers that accept it; either endpoint
/// may later restore its own outgoing direction with a newer trust fact.
public struct AppSyncTrustFact: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case trust, distrust }

    public let id: UUID
    public let timestamp: HybridLogicalTimestamp
    public let kind: Kind
    public let issuer: AppSyncPeer
    public let subject: AppSyncPeer
    public let signature: Data

    public var version: AppSyncTrustVersion { .init(timestamp: timestamp, eventID: id) }

    init(id: UUID = UUID(), timestamp: HybridLogicalTimestamp, kind: Kind,
         issuer: AppSyncPeer, subject: AppSyncPeer, signature: Data = Data()) {
        self.id = id; self.timestamp = timestamp; self.kind = kind
        self.issuer = issuer; self.subject = subject; self.signature = signature
    }

    func signed(by identity: AppSyncPeerIdentity) throws -> Self {
        guard identity.publicIdentity == issuer else { throw AppSyncTrustError.notIssuer }
        return .init(
            id: id, timestamp: timestamp, kind: kind, issuer: issuer, subject: subject,
            signature: try identity.sign(domain: Self.signatureDomain, payload: signaturePayload())
        )
    }

    public func verify() throws {
        guard !signature.isEmpty else { throw AppSyncTrustError.incompleteFact }
        try issuer.verify(
            signature: signature, domain: Self.signatureDomain, payload: signaturePayload()
        )
    }

    private static let signatureDomain = "com.eightybps.appsync.trust-fact.v2"

    private func signaturePayload() throws -> Data {
        struct Payload: Codable {
            let id: UUID; let timestamp: HybridLogicalTimestamp; let kind: Kind
            let issuer: AppSyncPeer; let subject: AppSyncPeer
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(
            id: id, timestamp: timestamp, kind: kind, issuer: issuer, subject: subject
        ))
    }
}

public enum AppSyncTrustError: Error, Equatable {
    case notIssuer, incompleteFact, invalidSignature, conflictingEvent
}

public enum AppSyncPeerTrustState: Equatable, Sendable {
    case local
    case directlyTrusted(since: AppSyncTrustVersion)
    case indirectlyTrusted(path: [AppSyncPeerID])
    case explicitlyDistrusted(since: AppSyncTrustVersion)
    case implicitlyDistrusted
    case unknown
}

public enum AppSyncTrustRecommendation: Equatable, Sendable {
    /// Replace transitive trust with an explicit, independently verified edge.
    case verifyDirectly
    /// The peer is not currently trusted; let the user either establish a
    /// verified edge or record an explicit distrust decision.
    case verifyOrDistrust
}

public struct AppSyncPeerTrustSuggestion: Equatable, Sendable {
    public let registration: AppSyncInstanceRegistration
    public let state: AppSyncPeerTrustState
    public let recommendation: AppSyncTrustRecommendation

    public init(registration: AppSyncInstanceRegistration, state: AppSyncPeerTrustState,
                recommendation: AppSyncTrustRecommendation) {
        self.registration = registration
        self.state = state
        self.recommendation = recommendation
    }
}

/// Durable event-ID set CRDT. All valid facts are retained, including facts the
/// local observer does not accept, so late delivery can reconstruct past views.
public final class AppSyncTrustStore: @unchecked Sendable {
    private struct Snapshot: Codable { var facts: [AppSyncTrustFact] }
    private let lock = NSLock()
    private let observer: AppSyncPeer
    private let fileURL: URL?
    private var factsByID: [UUID: AppSyncTrustFact]

    public init(observer: AppSyncPeer, fileURL: URL? = nil) throws {
        self.observer = observer; self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let facts = try JSONDecoder().decode(Snapshot.self, from: data).facts
            factsByID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        } else { factsByID = [:] }
    }

    public func merge(_ incoming: [AppSyncTrustFact]) throws -> Bool {
        try lock.withLock {
            var next = factsByID; var changed = false
            for fact in incoming {
                try fact.verify()
                if let existing = next[fact.id], existing != fact {
                    throw AppSyncTrustError.conflictingEvent
                }
                if next.updateValue(fact, forKey: fact.id) == nil { changed = true }
            }
            if changed { try persist(next); factsByID = next }
            return changed
        }
    }

    public func facts() -> [AppSyncTrustFact] {
        lock.withLock { factsByID.values.sorted { $0.version < $1.version } }
    }

    public func trusts(_ peer: AppSyncPeerID,
                       immediatelyBefore boundary: AppSyncTrustVersion? = nil) -> Bool {
        lock.withLock { evaluate(factsByID.values, boundary: boundary).trusted.contains(peer) }
    }

    public func state(of peer: AppSyncPeerID) -> AppSyncPeerTrustState {
        lock.withLock { stateUnlocked(of: peer) }
    }

    /// Returns only actionable peers that share at least one application with
    /// this instance. Registrations are signed, so unverified advertisements
    /// can never cause a peer to appear in trust UI.
    public func suggestions(
        among registrations: [AppSyncInstanceRegistration],
        localAppIDs: Set<AppSyncAppID>
    ) -> [AppSyncPeerTrustSuggestion] {
        lock.withLock {
            registrations.compactMap { registration in
                guard !registration.appIDs.isDisjoint(with: localAppIDs),
                      (try? registration.verify()) != nil,
                      registration.stablePeerID != observer.stableID else { return nil }
                let state = stateUnlocked(of: registration.stablePeerID)
                let recommendation: AppSyncTrustRecommendation
                switch state {
                case .indirectlyTrusted:
                    recommendation = .verifyDirectly
                case .implicitlyDistrusted, .unknown:
                    recommendation = .verifyOrDistrust
                case .local, .directlyTrusted, .explicitlyDistrusted:
                    return nil
                }
                return .init(
                    registration: registration, state: state, recommendation: recommendation
                )
            }
            .sorted { $0.registration.stablePeerID < $1.registration.stablePeerID }
        }
    }

    private func stateUnlocked(of peer: AppSyncPeerID) -> AppSyncPeerTrustState {
        if peer == observer.stableID { return .local }
        let result = evaluate(factsByID.values, boundary: nil)
        if let version = result.directTrust[peer], result.trusted.contains(peer) {
            return .directlyTrusted(since: version)
        }
        if result.trusted.contains(peer), let path = trustPath(
            to: peer, edges: result.positive, reachable: result.trusted
        ) {
            return .indirectlyTrusted(path: path)
        }
        if let version = result.explicitDistrust[peer] {
            return .explicitlyDistrusted(since: version)
        }
        if result.distrusted.contains(peer) { return .implicitlyDistrusted }
        return .unknown
    }

    private func evaluate(_ source: Dictionary<UUID, AppSyncTrustFact>.Values,
                          boundary: AppSyncTrustVersion?) -> Evaluation {
        var positive = Set<DirectedPeerEdge>()
        var distrusted = Set<AppSyncPeerID>()
        var directTrust: [AppSyncPeerID: AppSyncTrustVersion] = [:]
        var explicitDistrust: [AppSyncPeerID: AppSyncTrustVersion] = [:]
        let ordered = source.filter { boundary == nil || $0.version < boundary! }
            .sorted { $0.version < $1.version }
        for fact in ordered {
            guard (try? fact.verify()) != nil else { continue }
            let issuer = fact.issuer.stableID; let subject = fact.subject.stableID
            let trustedBefore = closure(positive: positive, excluding: distrusted)
            switch fact.kind {
            case .trust:
                positive.insert(.init(from: issuer, to: subject))
                if observer.stableID == issuer || trustedBefore.contains(issuer) {
                    distrusted.remove(subject)
                }
                if observer.stableID == issuer {
                    directTrust[subject] = fact.version
                    explicitDistrust[subject] = nil
                }
            case .distrust:
                if observer.stableID == subject {
                    distrusted.insert(issuer)
                    positive.remove(.init(from: issuer, to: subject))
                    positive.remove(.init(from: subject, to: issuer))
                } else if observer.stableID == issuer || trustedBefore.contains(issuer) {
                    distrusted.insert(subject)
                    positive.remove(.init(from: issuer, to: subject))
                    positive.remove(.init(from: subject, to: issuer))
                }
                if observer.stableID == issuer {
                    directTrust[subject] = nil
                    explicitDistrust[subject] = fact.version
                } else if observer.stableID == subject {
                    directTrust[issuer] = nil
                }
            }
        }
        return .init(
            trusted: closure(positive: positive, excluding: distrusted),
            distrusted: distrusted, positive: positive,
            directTrust: directTrust, explicitDistrust: explicitDistrust
        )
    }

    private func trustPath(to destination: AppSyncPeerID,
                           edges: Set<DirectedPeerEdge>,
                           reachable: Set<AppSyncPeerID>) -> [AppSyncPeerID]? {
        var queue: [[AppSyncPeerID]] = [[observer.stableID]]
        var visited: Set<AppSyncPeerID> = [observer.stableID]
        while !queue.isEmpty {
            let path = queue.removeFirst(); guard let last = path.last else { continue }
            for edge in edges where edge.from == last && reachable.contains(edge.to)
            && visited.insert(edge.to).inserted {
                let next = path + [edge.to]
                if edge.to == destination { return next }
                queue.append(next)
            }
        }
        return nil
    }

    private func closure(positive: Set<DirectedPeerEdge>,
                         excluding: Set<AppSyncPeerID>) -> Set<AppSyncPeerID> {
        var result: Set<AppSyncPeerID> = [observer.stableID]
        var changed = true
        while changed {
            changed = false
            for edge in positive where result.contains(edge.from) && !excluding.contains(edge.to) {
                changed = result.insert(edge.to).inserted || changed
            }
        }
        return result
    }

    private func persist(_ facts: [UUID: AppSyncTrustFact]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(Snapshot(facts: Array(facts.values)))
            .write(to: fileURL, options: .atomic)
    }
}

private struct Evaluation {
    let trusted: Set<AppSyncPeerID>
    let distrusted: Set<AppSyncPeerID>
    let positive: Set<DirectedPeerEdge>
    let directTrust: [AppSyncPeerID: AppSyncTrustVersion]
    let explicitDistrust: [AppSyncPeerID: AppSyncTrustVersion]
}

private struct DirectedPeerEdge: Hashable {
    let from: AppSyncPeerID
    let to: AppSyncPeerID
}
