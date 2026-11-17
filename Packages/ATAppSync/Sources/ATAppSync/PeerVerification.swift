import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// One emoji verification between this instance and a peer, as the UI sees it.
public struct AppSyncPeerVerification: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case initiator, responder }

    public enum Phase: Equatable, Sendable {
        /// Keys are being exchanged; there is nothing to compare yet.
        case exchangingKeys
        /// Both instances show `emoji`; the user compares them.
        case comparing
        /// This side confirmed; the other side hasn't yet.
        case waitingForPeer
        /// Both sides confirmed and each now trusts the other.
        case verified
        case cancelled(reason: String)
    }

    public let id: UUID
    public let role: Role
    public let peer: AppSyncPeer
    /// The emoji to compare, once keys are exchanged.
    public let emoji: [String]?
    public let phase: Phase
}

public enum AppSyncPeerVerificationFailure: Error, LocalizedError, Sendable {
    case unreachable, rejectedByPeer, peerBusy, invalidResponse, noSuchVerification

    public var errorDescription: String? {
        switch self {
        case .unreachable: "The other instance can't be reached on the local network."
        case .rejectedByPeer: "The other instance refused the verification."
        case .peerBusy: "The other instance is busy with other verifications. Try again in a few minutes."
        case .invalidResponse: "The other instance sent an invalid verification response."
        case .noSuchVerification: "That verification has ended."
        }
    }
}

/// Interactive emoji verification between two instances on the local network
/// (a short authentication string exchange).
///
/// The initiator commits to an ephemeral key, the responder answers with its
/// own, and the initiator reveals its key. Both derive the same secret, bound
/// to both identities and both ephemeral keys, and show seven emoji from it.
/// The commitment stops a man in the middle choosing keys after seeing the
/// other side's, so a mismatch is what a substitution looks like. When the
/// user confirms on both instances, each sends a MAC over the secret; each
/// trusts the other once it has confirmed and received a valid MAC. Every
/// message is signed with the sender's identity key.
final class AppSyncPeerVerifier: Sendable {
    static let route = "/appsync/v1/verify"
    private static let signatureDomain = "com.eightybps.appsync.peer-verification.v1"
    private static let lifetime: TimeInterval = 600
    /// Limits on verifications other instances start here, so an instance
    /// on the network can't flood the user with prompts.
    private static let maxIncomingInProgress = 3
    private static let maxStartsPerPeer = 3
    private static let startWindow: TimeInterval = 600

    struct Reply: Sendable {
        let status: Int
        var body = Data()
    }

    /// Derived session secrets, kept as bytes: swift-crypto's key types
    /// aren't Sendable on every platform, so key objects are rebuilt where
    /// they're used rather than stored.
    private struct Keys: Sendable {
        let mac: Data
        let emoji: [String]
        var macKey: SymmetricKey { SymmetricKey(data: mac) }
    }

    private struct Session: Sendable {
        let id: UUID
        let role: AppSyncPeerVerification.Role
        let peer: AppSyncPeer
        let peerEndpoint: URL
        /// This side's ephemeral private key, as raw bytes (see `Keys`).
        let ephemeral: Data
        /// The initiator's commitment, held by the responder until the reveal.
        var commitment: Data?
        var keys: Keys?
        var localConfirmed = false
        var remoteConfirmed = false
        var phase: AppSyncPeerVerification.Phase = .exchangingKeys
        let startedAt = Date()

        var view: AppSyncPeerVerification {
            .init(id: id, role: role, peer: peer, emoji: keys?.emoji, phase: phase)
        }
    }

    let changes = AppSyncChangeSignal()
    private let identity: InstanceIdentity
    private let sessions = Mutex<[UUID: Session]>([:])
    private let recentStarts = Mutex<[AppSyncPeerID: [Date]]>([:])
    private let localRegistration: @Sendable () -> AppSyncInstanceRegistration?
    private let onVerified = Mutex<(@Sendable (AppSyncPeer) throws -> Void)?>(nil)
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    init(identity: InstanceIdentity,
         localRegistration: @escaping @Sendable () -> AppSyncInstanceRegistration?) {
        self.identity = identity
        self.localRegistration = localRegistration
    }

    deinit { session.invalidateAndCancel() }

    /// Called once both sides have confirmed; records trust in the peer.
    func setTrustHandler(_ handler: @escaping @Sendable (AppSyncPeer) throws -> Void) {
        onVerified.withLock { $0 = handler }
    }

    func verifications() -> [AppSyncPeerVerification] {
        sessions.withLock { sessions in
            let cutoff = Date().addingTimeInterval(-Self.lifetime)
            sessions = sessions.filter { $0.value.startedAt >= cutoff }
            return sessions.values.sorted { $0.startedAt < $1.startedAt }.map(\.view)
        }
    }

    func dismiss(_ id: UUID) {
        sessions.withLock { _ = $0.removeValue(forKey: id) }
        changes.send()
    }

    // MARK: Initiator

    func start(with registration: AppSyncInstanceRegistration) async throws -> UUID {
        try registration.verify()
        guard let endpoint = Self.endpoint(from: registration),
              let ownRegistration = localRegistration() else {
            throw AppSyncPeerVerificationFailure.unreachable
        }
        let id = UUID()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ownKey = ephemeral.publicKey.rawRepresentation
        let ephemeralBytes = ephemeral.rawRepresentation
        sessions.withLock {
            $0[id] = Session(id: id, role: .initiator, peer: registration.peer,
                             peerEndpoint: endpoint, ephemeral: ephemeralBytes)
        }
        changes.send()
        do {
            let start = try Message(
                kind: .start, session: id, sender: identity.publicIdentity,
                recipient: registration.stablePeerID, registration: ownRegistration,
                commitment: Self.commitment(session: id, key: ownKey)
            ).signed(by: identity)
            let accept = try await post(start, to: endpoint)
            guard accept.kind == .accept, accept.session == id,
                  accept.sender == registration.peer,
                  accept.recipient == identity.publicIdentity.stableID,
                  let peerKey = accept.ephemeralKey else {
                throw AppSyncPeerVerificationFailure.invalidResponse
            }
            let keys = try Self.derive(
                session: id, own: ephemeralBytes, peerKey: peerKey,
                initiator: identity.publicIdentity, responder: registration.peer,
                initiatorKey: ownKey, responderKey: peerKey
            )
            let reveal = try Message(
                kind: .reveal, session: id, sender: identity.publicIdentity,
                recipient: registration.stablePeerID, ephemeralKey: ownKey
            ).signed(by: identity)
            _ = try await postExpectingNoContent(reveal, to: endpoint)
            update(id) { $0.keys = keys; $0.phase = .comparing }
        } catch {
            update(id) { $0.phase = .cancelled(reason: error.localizedDescription) }
            throw error
        }
        return id
    }

    // MARK: Both sides

    /// The user says the emoji match.
    func confirm(_ id: UUID) async throws {
        guard let session = sessions.withLock({ $0[id] }), let keys = session.keys else {
            throw AppSyncPeerVerificationFailure.noSuchVerification
        }
        update(id) { $0.localConfirmed = true }
        let message = try Message(
            kind: .confirm, session: id, sender: identity.publicIdentity,
            recipient: session.peer.stableID,
            mac: Self.mac(session: id, sender: identity.publicIdentity.stableID, key: keys.macKey)
        ).signed(by: identity)
        do {
            _ = try await postExpectingNoContent(message, to: session.peerEndpoint)
        } catch {
            update(id) { $0.phase = .cancelled(reason: error.localizedDescription) }
            throw error
        }
        completeIfConfirmed(id)
    }

    /// The user says the emoji differ, or gives up.
    func cancel(_ id: UUID) async {
        guard let session = sessions.withLock({ $0[id] }) else { return }
        update(id) { $0.phase = .cancelled(reason: "You cancelled the verification.") }
        if let message = try? Message(
            kind: .cancel, session: id, sender: identity.publicIdentity,
            recipient: session.peer.stableID
        ).signed(by: identity) {
            _ = try? await postExpectingNoContent(message, to: session.peerEndpoint)
        }
    }

    // MARK: Server side

    /// Handles a verification message from another instance. Runs on the LAN
    /// server's event loop, so it never waits on the network.
    func handle(_ data: Data) -> Reply {
        guard let message = try? JSONDecoder().decode(Message.self, from: data),
              (try? message.verify()) != nil,
              message.recipient == identity.publicIdentity.stableID else {
            return Reply(status: 403)
        }
        switch message.kind {
        case .start: return handleStart(message)
        case .reveal: return handleReveal(message)
        case .confirm: return handleConfirm(message)
        case .cancel:
            let known = update(message.session, from: message.sender) {
                $0.phase = .cancelled(reason: "The other instance cancelled the verification.")
            }
            return Reply(status: known ? 204 : 404)
        case .accept:
            return Reply(status: 400)
        }
    }

    private func handleStart(_ message: Message) -> Reply {
        guard let registration = message.registration, (try? registration.verify()) != nil,
              registration.peer == message.sender,
              let endpoint = Self.endpoint(from: registration),
              let commitment = message.commitment,
              sessions.withLock({ $0[message.session] == nil }) else {
            return Reply(status: 400)
        }
        guard admitIncoming(from: message.sender) else { return Reply(status: 429) }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephemeralBytes = ephemeral.rawRepresentation
        guard let accept = try? Message(
            kind: .accept, session: message.session, sender: identity.publicIdentity,
            recipient: message.sender.stableID,
            ephemeralKey: ephemeral.publicKey.rawRepresentation
        ).signed(by: identity), let body = try? JSONEncoder().encode(accept) else {
            return Reply(status: 500)
        }
        sessions.withLock {
            var session = Session(id: message.session, role: .responder, peer: message.sender,
                                  peerEndpoint: endpoint, ephemeral: ephemeralBytes)
            session.commitment = commitment
            $0[message.session] = session
        }
        changes.send()
        return Reply(status: 200, body: body)
    }

    private func handleReveal(_ message: Message) -> Reply {
        guard let initiatorKey = message.ephemeralKey,
              let session = sessions.withLock({ $0[message.session] }),
              session.role == .responder, session.peer == message.sender, session.keys == nil,
              let commitment = session.commitment,
              Self.commitment(session: message.session, key: initiatorKey) == commitment,
              let keys = try? Self.derive(
                session: message.session, own: session.ephemeral, peerKey: initiatorKey,
                initiator: message.sender, responder: identity.publicIdentity,
                initiatorKey: initiatorKey,
                responderKey: (try? P256.KeyAgreement.PrivateKey(rawRepresentation: session.ephemeral))?
                    .publicKey.rawRepresentation ?? Data()
              ) else {
            update(message.session, from: message.sender) {
                $0.phase = .cancelled(reason: "The other instance's key didn't match its commitment.")
            }
            return Reply(status: 400)
        }
        update(message.session) { $0.keys = keys; $0.phase = .comparing }
        return Reply(status: 204)
    }

    private func handleConfirm(_ message: Message) -> Reply {
        guard let mac = message.mac,
              let session = sessions.withLock({ $0[message.session] }),
              session.peer == message.sender, let keys = session.keys,
              HMAC<SHA256>.isValidAuthenticationCode(
                mac, authenticating: Self.macInput(session: message.session,
                                                   sender: message.sender.stableID),
                using: keys.macKey
              ) else {
            return Reply(status: 400)
        }
        update(message.session) { $0.remoteConfirmed = true }
        completeIfConfirmed(message.session)
        return Reply(status: 204)
    }

    // MARK: Helpers

    /// Whether to accept a verification another instance starts: at most one
    /// in progress per instance, a few in progress overall, and a few starts
    /// per instance within `startWindow`.
    private func admitIncoming(from peer: AppSyncPeer) -> Bool {
        let inProgress = sessions.withLock { sessions in
            sessions.values.filter { session in
                switch session.phase {
                case .exchangingKeys, .comparing, .waitingForPeer: true
                case .verified, .cancelled: false
                }
            }
        }
        if inProgress.contains(where: { $0.peer == peer }) { return false }
        if inProgress.filter({ $0.role == .responder }).count >= Self.maxIncomingInProgress { return false }
        let now = Date()
        return recentStarts.withLock { starts in
            var times = (starts[peer.stableID] ?? []).filter { now.timeIntervalSince($0) < Self.startWindow }
            guard times.count < Self.maxStartsPerPeer else {
                starts[peer.stableID] = times
                return false
            }
            times.append(now)
            starts[peer.stableID] = times
            starts = starts.filter { !$0.value.isEmpty }
            return true
        }
    }

    private func completeIfConfirmed(_ id: UUID) {
        guard let session = sessions.withLock({ $0[id] }) else { return }
        guard session.localConfirmed else { return }
        guard session.remoteConfirmed else {
            update(id) { $0.phase = .waitingForPeer }
            return
        }
        let trust = onVerified.withLock { $0 }
        do {
            try trust?(session.peer)
            update(id) { $0.phase = .verified }
        } catch {
            update(id) { $0.phase = .cancelled(reason: error.localizedDescription) }
        }
    }

    @discardableResult
    private func update(_ id: UUID, from sender: AppSyncPeer? = nil,
                        _ change: (inout Session) -> Void) -> Bool {
        let updated = sessions.withLock { sessions -> Bool in
            guard var session = sessions[id],
                  sender == nil || session.peer == sender else { return false }
            change(&session)
            sessions[id] = session
            return true
        }
        if updated { changes.send() }
        return updated
    }

    private func post(_ message: Message, to url: URL) async throws -> Message {
        let (data, status) = try await send(message, to: url)
        if status == 429 { throw AppSyncPeerVerificationFailure.peerBusy }
        guard status == 200 else { throw AppSyncPeerVerificationFailure.rejectedByPeer }
        guard let reply = try? JSONDecoder().decode(Message.self, from: data),
              (try? reply.verify()) != nil else {
            throw AppSyncPeerVerificationFailure.invalidResponse
        }
        return reply
    }

    private func postExpectingNoContent(_ message: Message, to url: URL) async throws -> Int {
        let (_, status) = try await send(message, to: url)
        guard (200..<300).contains(status) else { throw AppSyncPeerVerificationFailure.rejectedByPeer }
        return status
    }

    private func send(_ message: Message, to url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(message)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            throw AppSyncPeerVerificationFailure.unreachable
        }
        return (data, http.statusCode)
    }

    private static func endpoint(from registration: AppSyncInstanceRegistration) -> URL? {
        guard let lan = registration.lanEndpoint,
              var components = URLComponents(url: lan, resolvingAgainstBaseURL: false) else { return nil }
        components.path = route
        components.query = nil
        return components.url
    }

    private static func commitment(session: UUID, key: Data) -> Data {
        var input = Data("appsync-sas-commitment-v1".utf8)
        input.append(Data(session.uuidString.lowercased().utf8))
        input.append(key)
        return Data(SHA256.hash(data: input))
    }

    private static func derive(
        session: UUID, own ownBytes: Data, peerKey: Data,
        initiator: AppSyncPeer, responder: AppSyncPeer, initiatorKey: Data, responderKey: Data
    ) throws -> Keys {
        let own = try P256.KeyAgreement.PrivateKey(rawRepresentation: ownBytes)
        let shared = try own.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        )
        var transcript = Data("appsync-sas-v1".utf8)
        transcript.append(Data(session.uuidString.lowercased().utf8))
        for part in [initiator.signingKey, initiator.encryptionKey,
                     responder.signingKey, responder.encryptionKey,
                     initiatorKey, responderKey] {
            transcript.append(UInt8(part.count))
            transcript.append(part)
        }
        let salt = Data(SHA256.hash(data: transcript))
        let mac = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("appsync sas mac".utf8),
            outputByteCount: 32
        )
        let emojiBytes = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("appsync sas emoji".utf8),
            outputByteCount: 7
        ).withUnsafeBytes { Array($0) }
        // 64 symbols divide 256 evenly, so each byte gives an unbiased 6 bits.
        let emoji = emojiBytes.map { VerificationEmoji.values[Int($0) % VerificationEmoji.values.count] }
        return Keys(mac: mac.withUnsafeBytes { Data($0) }, emoji: emoji)
    }

    private static func macInput(session: UUID, sender: AppSyncPeerID) -> Data {
        var input = Data("appsync-sas-confirm-v1".utf8)
        input.append(Data(session.uuidString.lowercased().utf8))
        input.append(Data(sender.rawValue.utf8))
        return input
    }

    private static func mac(session: UUID, sender: AppSyncPeerID, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: macInput(session: session, sender: sender), using: key))
    }

    // MARK: Wire format

    private struct Message: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case start, accept, reveal, confirm, cancel }

        let kind: Kind
        let session: UUID
        let sender: AppSyncPeer
        let recipient: AppSyncPeerID
        var registration: AppSyncInstanceRegistration?
        var commitment: Data?
        var ephemeralKey: Data?
        var mac: Data?
        var signature = Data()

        private func payload() throws -> Data {
            var unsigned = self
            unsigned.signature = Data()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(unsigned)
        }

        func signed(by identity: InstanceIdentity) throws -> Self {
            var signed = self
            signed.signature = try identity.sign(domain: AppSyncPeerVerifier.signatureDomain,
                                                 payload: payload())
            return signed
        }

        func verify() throws {
            try sender.verify(signature: signature, domain: AppSyncPeerVerifier.signatureDomain,
                              payload: payload())
        }
    }
}
