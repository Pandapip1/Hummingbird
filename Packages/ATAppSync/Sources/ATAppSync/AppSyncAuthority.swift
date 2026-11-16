import ATProtoKit
import Foundation

public enum AppSyncAuthority {
    public static let did = DID(rawValue: "did:plc:ku5k2fkivxead2a3h46pht7x")!
    public static let domain = "appsync.eightybps.com"
    public static let protocolID = NSID(rawValue: "com.eightybps.appsync")!
    public static let protocolAppID = AppSyncAppID(rawValue: "com.eightybps.appsync")!
    /// The DNS-SD service type instances advertise and browse on the LAN.
    /// Apple platforms only allow it if the app lists it in its Info.plist's
    /// NSBonjourServices.
    public static let bonjourServiceType = "_atproto-appsync._tcp"
}

/// Reverse-DNS identifiers understood by an instance. Registrations are signed
/// as part of the instance descriptor so another client cannot broaden them.
public struct AppSyncAppID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ part in
            !part.isEmpty && part.first?.isLetter == true &&
                part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return nil }
        self.rawValue = rawValue.lowercased()
    }
}
