import Foundation
import SwiftOpenUI

/// A persistence-aware entry point for platforms that do not provide their
/// own launch screen. Persisted state is read and decoded off the main actor.
@MainActor
public struct PreparedHummingbirdRoot: View {
    @State private var root: HummingbirdRoot?
    @State private var profileID: UUID?
    @Environment(\.openWindow) private var openWindow
    private let opensProfilesInNewWindows: Bool

    public init(profileID: UUID? = nil, opensProfilesInNewWindows: Bool = false) {
        _profileID = State(wrappedValue: profileID)
        self.opensProfilesInNewWindows = opensProfilesInNewWindows
    }

    public var body: some View {
        Group {
            if let root {
                root.environment(
                    \.openHummingbirdProfile,
                    OpenHummingbirdProfileAction { id in
                        if opensProfilesInNewWindows {
                            openWindow(value: id)
                            return
                        }
                        Task {
                            await Storage.flush()
                            UserDefaults.standard.set(id.uuidString, forKey: "appsync.localProfileID")
                            profileID = id
                            self.root = nil
                        }
                    }
                )
            } else {
                ProgressView("Loading Hummingbird…")
                    .task(id: profileID) {
                        if let profileID { root = await HummingbirdRoot.prepared(profileID: profileID) }
                        else { root = await HummingbirdRoot.prepared() }
                    }
            }
        }
    }
}
