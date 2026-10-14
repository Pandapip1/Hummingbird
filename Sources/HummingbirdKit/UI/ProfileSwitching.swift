import Foundation
import SwiftOpenUI

public struct OpenHummingbirdProfileAction: Sendable {
    private let handler: @MainActor @Sendable (UUID) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }) {
        self.handler = handler
    }

    @MainActor public func callAsFunction(_ profileID: UUID) { handler(profileID) }
}

private struct OpenHummingbirdProfileKey: EnvironmentKey {
    static let defaultValue = OpenHummingbirdProfileAction()
}

public extension EnvironmentValues {
    var openHummingbirdProfile: OpenHummingbirdProfileAction {
        get { self[OpenHummingbirdProfileKey.self] }
        set { self[OpenHummingbirdProfileKey.self] = newValue }
    }
}
