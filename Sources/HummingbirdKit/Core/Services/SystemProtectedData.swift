import ATAppSync
import Foundation
import PlatformSupport

/// The platform's data-protection state, from PlatformSupport, for ATAppSync
/// and the stores built on it: the system's protected-data availability and
/// file protection on iOS, iPadOS, tvOS and visionOS; always available, and
/// no protection classes, on macOS and Linux. One code path everywhere.
public struct SystemProtectedData: ProtectedDataAvailability {
    /// Starts following the system's state; create it on the main actor at launch.
    @MainActor
    public init() {
        ProtectedData.startObserving()
    }

    public var isProtectedDataAvailable: Bool { ProtectedData.isAvailable }

    public func observeProtectedDataAvailability(_ handler: @escaping @Sendable (Bool) -> Void) {
        ProtectedData.observe(handler)
    }

    public func setProtection(_ protection: AppSyncFileProtection, for url: URL) throws {
        try FileProtection.set(Self.fileProtection(protection), for: url)
    }

    public func protection(of url: URL) -> AppSyncFileProtection? {
        switch FileProtection.current(of: url) {
        case .complete?: .complete
        case .completeUnlessOpen?: .completeUnlessOpen
        case .completeUntilFirstUserAuthentication?: .completeUntilFirstUserAuthentication
        case .unprotected?: .unprotected
        case nil: nil
        }
    }

    private static func fileProtection(_ protection: AppSyncFileProtection) -> FileProtection.Class {
        switch protection {
        case .complete: .complete
        case .completeUnlessOpen: .completeUnlessOpen
        case .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication
        case .unprotected: .unprotected
        }
    }
}
