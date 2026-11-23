import SwiftUI
import SwiftOpenUI
import HummingbirdKit
#if os(iOS) || os(tvOS)
import AVKit
#endif

@main
struct HummingbirdApp: App {
    init() {
        // How runaway plugin scripts are stopped: the strongest this build and platform allow
        // (DirectDistribution.swift, PluginExecutionLimits). Cheap: no process starts until a plugin runs.
        PluginExecutionSetup.install()
        #if DEBUG && os(iOS)
        // Measurement only: launched with HUMMINGBIRD_BACKGROUND_BENCH=1 (scripts/measure-background-calls).
        BackgroundCallBench.startIfRequested()
        #endif
    }

    // Nothing runs before the first frame: the splash is drawn first, then
    // the stores, credential checks and MetricKit start away from the main
    // thread (`LaunchGate`).

    var body: some Scene {
        #if os(macOS)
        WindowGroup(for: UUID.self) { profileID in
            LaunchGate(profileID: profileID.wrappedValue)
        }
        .hummingbirdCommands()
        #else
        WindowGroup {
            LaunchGate()
        }
        .hummingbirdCommands()
        #endif
    }
}

/// Shows the splash on the very first frame, then does everything else away
/// from the main thread: opening the stores, probing the credential store,
/// starting MetricKit and loading the profile.
///
/// AVPlayerViewController performs substantial one-time AVKit setup on the main
/// thread. Pay that cost behind launch chrome so the first player navigation
/// does not freeze an already-interactive interface.
@MainActor
private struct LaunchGate: View {
    @State private var preparedRoot: HummingbirdRoot?
    @State private var selectedProfileID: UUID?
    /// The user's real data, once opened. This entry point is the only place
    /// that opens it.
    @State private var stores: AppDataStores?
    #if os(macOS)
    @State private var storageDecision: CredentialStorageDecision?
    #endif
    @State private var credentialsLocked = false
    @State private var unlockFailure: String?
    @Environment(\.openIdentifiedWindow) private var openIdentifiedWindow

    init(profileID: UUID? = nil) {
        _selectedProfileID = State(initialValue: profileID)
    }

    /// What launch needs before a profile can open, found off the main thread.
    private struct Opened: Sendable {
        let stores: AppDataStores
        #if os(macOS)
        let storageDecision: CredentialStorageDecision?
        #endif
        let credentialsLocked: Bool
    }

    @concurrent
    private static func open(protectedData: SystemProtectedData) async -> Opened {
        let stores = AppDataStores.live(protectedData: protectedData)
        #if os(macOS)
        // Probes the credential store before anything is written to it.
        let decision = stores.keychain.flatMap(CredentialStorageDecision.pending(for:))
        return Opened(stores: stores, storageDecision: decision,
                      credentialsLocked: stores.credentialStore.requiresExplicitUnlock())
        #else
        return Opened(stores: stores, credentialsLocked: stores.credentialStore.requiresExplicitUnlock())
        #endif
    }

    @concurrent
    private static func requiresUnlock(_ stores: AppDataStores) async -> Bool {
        stores.credentialStore.requiresExplicitUnlock()
    }

    var body: some View {
        if let preparedRoot, let stores {
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
            .onAppear { DispatchQueue.main.async { LaunchTiming.mark(.interfaceVisible) } }
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
                    if let storageDecision, let stores, let store = stores.keychain {
                        CredentialStorageDecisionView(decision: storageDecision, store: store) {
                            Task {
                                credentialsLocked = await Self.requiresUnlock(stores)
                                self.storageDecision = nil
                            }
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
            .onAppear { DispatchQueue.main.async { LaunchTiming.mark(.splashVisible) } }
            .task(id: "\(stores != nil):\(awaitingStorageDecision):\(credentialsLocked):\(selectedProfileID?.uuidString ?? "default")") {
                guard let stores else {
                    let protectedData = SystemProtectedData()
                    // Launched while the device is locked (and nothing yet
                    // queued): the databases can't be read, so opening them
                    // now would start the library empty and later writes
                    // would replace what is stored. The splash stays until
                    // the first unlock.
                    await protectedData.waitUntilAvailable()
                    guard !Task.isCancelled else { return }
                    let opened = await Self.open(protectedData: protectedData)
                    #if os(macOS)
                    storageDecision = opened.storageDecision
                    #endif
                    credentialsLocked = opened.credentialsLocked
                    self.stores = opened.stores
                    LaunchTiming.mark(.storesOpened)
                    // MetricKit crash, hang, CPU and disk-write diagnostics
                    // and daily metrics, in every build: logged and kept for
                    // export from Settings.
                    PerformanceReports.start(stores: opened.stores)
                    return
                }
                guard !awaitingStorageDecision, !credentialsLocked else { return }
                // Give SwiftUI a frame to put the splash on screen before the
                // intentionally synchronous AVKit initialization begins.
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                #if os(iOS) || os(tvOS)
                prewarmAVKit()
                #endif
                let root = await HummingbirdRoot.prepared(stores: stores, profileID: selectedProfileID)
                LaunchTiming.mark(.rootPrepared)
                preparedRoot = root
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
                        guard let stores else { return }
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
