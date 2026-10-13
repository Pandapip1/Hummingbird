import SwiftUI
import HummingbirdKit
#if os(iOS) || os(tvOS)
import AVKit
#endif

@main
struct HummingbirdApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchGate()
        }
    }
}

/// AVPlayerViewController performs substantial one-time AVKit setup on the main
/// thread. Pay that cost behind launch chrome so the first player navigation
/// does not freeze an already-interactive interface.
@MainActor
private struct LaunchGate: View {
    @State private var preparedRoot: HummingbirdRoot?

    var body: some View {
        if let preparedRoot {
            preparedRoot
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
                    ProgressView()
                }
                .foregroundStyle(.white)
            }
            .task {
                // Give SwiftUI a frame to put the splash on screen before the
                // intentionally synchronous AVKit initialization begins.
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                #if os(iOS) || os(tvOS)
                prewarmAVKit()
                #endif
                preparedRoot = await HummingbirdRoot.prepared()
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
