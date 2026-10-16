import Foundation
import SwiftOpenUI
import CredentialStorage

/// A persistence-aware entry point for platforms that do not provide their
/// own launch screen. Persisted state is read and decoded off the main actor.
@MainActor
public struct PreparedHummingbirdRoot: View {
    @State private var root: HummingbirdRoot?
    @State private var profileID: UUID?
    @State private var credentialsLocked = {
        AuthKeychain.registerVault()
        // The access probe is non-interactive. Only present the explicit
        // ceremony when protected credentials actually require user presence;
        // an already-accessible or empty vault can proceed immediately.
        return CredentialVaultManager.shared.requiresExplicitUnlock
    }()
    @State private var unlockFailure: String?
    @Environment(\.openIdentifiedWindow) private var openIdentifiedWindow
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
                            openIdentifiedWindow(id)
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
                CenteredStatusContainer {
                    VStack(spacing: 12) {
                        if credentialsLocked {
                            Image(systemName: "lock.fill").font(.largeTitle)
                            Text("Unlock Hummingbird")
                                .font(.title2.bold())
                            Text("Unlock your protected plugin credentials to finish opening this profile.")
                                .foregroundStyle(.secondary)
                            Button("Unlock") {
                                Task {
                                    do {
                                        try await Task.detached {
                                            try CredentialVaultManager.shared.requestUnlock()
                                        }.value
                                        credentialsLocked = false
                                        unlockFailure = nil
                                    } catch {
                                        unlockFailure = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if let unlockFailure {
                                Text("Hummingbird couldn’t unlock your credentials: \(unlockFailure)")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView("Loading Hummingbird…")
                        }
                    }
                    .padding()
                }
                .task(id: "\(credentialsLocked):\(profileID?.uuidString ?? "default")") {
                    guard !credentialsLocked else { return }
                    if let profileID { root = await HummingbirdRoot.prepared(profileID: profileID) }
                    else { root = await HummingbirdRoot.prepared() }
                }
            }
        }
    }
}
