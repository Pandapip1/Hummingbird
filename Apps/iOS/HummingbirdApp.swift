import SwiftUI
import HummingbirdKit
import DebugKit
#if os(iOS) || os(tvOS)
import AVKit
#endif

@main
struct HummingbirdApp: App {
    init() {
        #if DEBUG && os(iOS)
        RenderHangDiagnostics.start()
        RollingMainThreadSampler.start()
        if let root = try? RenderDiagnosticsStorage.root() {
            DebugServer.shared.registerDiagnosticDirectory("render-stalls", url: root)
            DebugServer.shared.registerDiagnosticDirectory("metric-hangs", url: root.appendingPathComponent("metric-hangs"))
            DebugServer.shared.registerDiagnosticDirectory("stall-samples", url: root.appendingPathComponent("stall-samples"))
        }
        #endif
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
    @State private var credentialsLocked = AuthKeychain.store.requiresExplicitUnlock()
    @State private var unlockFailure: String?
    @Environment(\.openIdentifiedWindow) private var openIdentifiedWindow

    init(profileID: UUID? = nil) {
        _selectedProfileID = State(initialValue: profileID)
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
                        await Storage.flush()
                        UserDefaults.standard.set(id.uuidString, forKey: "appsync.localProfileID")
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
                    if credentialsLocked {
                        Text("Unlock your protected plugin credentials to continue.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Unlock") {
                            Task {
                                do {
                                    try await Task.detached {
                                        try AuthKeychain.store.requestUnlock()
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
                .foregroundStyle(.white)
            }
            .task(id: "\(credentialsLocked):\(selectedProfileID?.uuidString ?? "default")") {
                guard !credentialsLocked else { return }
                // Give SwiftUI a frame to put the splash on screen before the
                // intentionally synchronous AVKit initialization begins.
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                #if os(iOS) || os(tvOS)
                prewarmAVKit()
                #endif
                if let selectedProfileID {
                    preparedRoot = await HummingbirdRoot.prepared(profileID: selectedProfileID)
                } else {
                    preparedRoot = await HummingbirdRoot.prepared()
                }
            }
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
