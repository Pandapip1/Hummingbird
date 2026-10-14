import Crypto
import Foundation

public struct AppSyncInstanceRegistration: Codable, Hashable, Sendable {
    public static let signatureDomain = "com.eightybps.appsync.instance-registration.v1"

    public let instanceID: UUID
    public let signingKey: Data
    public let encryptionKey: Data
    public let appIDs: Set<AppSyncAppID>
    public let lanEndpoint: URL?
    public let lanAppendCapability: Data?
    public let signature: Data

    private struct Unsigned: Codable {
        let instanceID: UUID
        let signingKey: Data
        let encryptionKey: Data
        let appIDs: [AppSyncAppID]
        let lanEndpoint: URL?
        let lanAppendCapability: Data?
    }

    public init(instanceID: UUID, encryptionKey: Data, appIDs: Set<AppSyncAppID>,
                lanEndpoint: URL?, lanAppendCapability: Data?, signer: JournalEventSigner) throws {
        guard signer.instanceID == instanceID else { throw AppSyncRegistrationError.identityMismatch }
        let unsigned = Unsigned(
            instanceID: instanceID, signingKey: signer.publicKey, encryptionKey: encryptionKey,
            appIDs: appIDs.sorted { $0.rawValue < $1.rawValue }, lanEndpoint: lanEndpoint,
            lanAppendCapability: lanAppendCapability
        )
        self.instanceID = instanceID
        signingKey = signer.publicKey
        self.encryptionKey = encryptionKey
        self.appIDs = appIDs
        self.lanEndpoint = lanEndpoint
        self.lanAppendCapability = lanAppendCapability
        signature = try signer.sign(
            domain: Self.signatureDomain, payload: Self.encoder.encode(unsigned)
        )
    }

    public func verify() throws {
        let unsigned = Unsigned(
            instanceID: instanceID, signingKey: signingKey, encryptionKey: encryptionKey,
            appIDs: appIDs.sorted { $0.rawValue < $1.rawValue }, lanEndpoint: lanEndpoint,
            lanAppendCapability: lanAppendCapability
        )
        var transcript = Data(Self.signatureDomain.utf8)
        transcript.append(0)
        transcript.append(try Self.encoder.encode(unsigned))
        let key = try P256.Signing.PublicKey(rawRepresentation: signingKey)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(parsed, for: transcript) else {
            throw AppSyncRegistrationError.invalidSignature
        }
    }

    public func recognizes(_ appID: AppSyncAppID) -> Bool { appIDs.contains(appID) }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum AppSyncRegistrationError: Error, Equatable {
    case identityMismatch, invalidSignature
}
