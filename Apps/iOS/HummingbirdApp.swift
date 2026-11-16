import SwiftUI
import SwiftOpenUI
import HummingbirdKit
#if os(iOS) || os(tvOS)
import AVKit
#endif

@main
struct HummingbirdApp: App {
    init() {
        // MetricKit crash, hang, CPU and disk-write diagnostics and daily
        // metrics, in every build: logged and kept for export from Settings.
        PerformanceReports.start(stores: AppDataStores.live())
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup(for: UUID.self) { profileID in
            LaunchGate(profileID: profileID.wrappedValue)
        }
        #else
        WindowGroup {
            LaunchGate()
        }
        #endif
    }
}

/// AVPlayerViewController performs substantial one-time AVKit setup on the main
/// thread. Pay that cost behind launch chrome so the first player navigation
/// does not freeze an already-interactive interface.
@MainActor
private struct LaunchGate: View {
    @State private var preparedRoot: HummingbirdRoot?
    @State private var selectedProfileID: UUID?
    #if os(macOS)
    @State private var storageDecision: CredentialStorageDecision?
    #endif
    @State private var credentialsLocked: Bool
    @State private var unlockFailure: String?
    @Environment(\.openIdentifiedWindow) private var openIdentifiedWindow

    /// The user's real data. This entry point is the only place that opens it.
    private let stores = AppDataStores.live()

    init(profileID: UUID? = nil) {
        _selectedProfileID = State(initialValue: profileID)
        #if os(macOS)
        // Probes the credential store before anything is written to it.
        _storageDecision = State(initialValue: stores.keychain.flatMap(CredentialStorageDecision.pending(for:)))
        #endif
        _credentialsLocked = State(initialValue: stores.credentialStore.requiresExplicitUnlock())
    }

    var body: some View {
        if let preparedRoot {
            preparedRoot.environment(
                \.openHummingbirdProfile,
                OpenHummingbirdProfileAction { id in
                    #if os(macOS)
                    openIdentifiedWindow(id)
                    #else
                    Task {
                        await stores.selectLocalProfile(id)
                        selectedProfileID = id
                        self.preparedRoot = nil
                    }
                    #endif
                }
            )
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Image("HummingbirdSplash")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    Text("Hummingbird").font(.title.bold())
                    #if os(macOS)
                    if let storageDecision, let store = stores.keychain {
                        CredentialStorageDecisionView(decision: storageDecision, store: store) {
                            self.storageDecision = nil
                            credentialsLocked = stores.credentialStore.requiresExplicitUnlock()
                        }
                    } else {
                        unlockOrProgress
                    }
                    #else
                    unlockOrProgress
                    #endif
                }
                .foregroundStyle(.white)
            }
            .task(id: "\(awaitingStorageDecision):\(credentialsLocked):\(selectedProfileID?.uuidString ?? "default")") {
                guard !awaitingStorageDecision, !credentialsLocked else { return }
                // Give SwiftUI a frame to put the splash on screen before the
                // intentionally synchronous AVKit initialization begins.
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                #if os(iOS) || os(tvOS)
                prewarmAVKit()
                #endif
                preparedRoot = await HummingbirdRoot.prepared(stores: stores, profileID: selectedProfileID)
            }
        }
    }

    /// Opening a profile reads and writes credentials, so any storage question
    /// is answered first.
    private var awaitingStorageDecision: Bool {
        #if os(macOS)
        storageDecision != nil
        #else
        false
        #endif
    }

    @ViewBuilder
    private var unlockOrProgress: some View {
        if credentialsLocked {
            Text("Unlock your protected plugin credentials to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Unlock") {
                Task {
                    do {
                        try await Task.detached {
                            try stores.credentialStore.requestUnlock()
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
            ProgressView()
        }
    }

    #if os(iOS) || os(tvOS)
    private func prewarmAVKit() {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.player = AVPlayer()
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        withExtendedLifetime(controller) {}
    }
    #endif
}
