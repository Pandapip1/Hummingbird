import SwiftOpenUI

/// A persistence-aware entry point for platforms that do not provide their
/// own launch screen. Persisted state is read and decoded off the main actor.
@MainActor
public struct PreparedHummingbirdRoot: View {
    @State private var root: HummingbirdRoot?

    public init() {}

    public var body: some View {
        Group {
            if let root {
                root
            } else {
                ProgressView("Loading Hummingbird…")
                    .task { root = await HummingbirdRoot.prepared() }
            }
        }
    }
}
