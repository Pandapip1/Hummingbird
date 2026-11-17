import SwiftOpenUI
import Foundation

public enum AdvancedVideoPlayerLayout {
    public static let controlBarMinimumHeight: CGFloat = 44
    public static let minimumBarSeparation: CGFloat = 24
    public static let minimumHeight = 2 * (controlBarMinimumHeight + 2 * 9) + 2 * 8 + 2 * 6 + minimumBarSeparation

    public static func usesStackedTransport(width: CGFloat) -> Bool { width < 340 }
    public static func usesStackedAccessoryControls(width: CGFloat) -> Bool { width < 280 }

    public static func minimumHeight(width: CGFloat) -> CGFloat {
        let transportRows: CGFloat = usesStackedTransport(width: width) ? 2 : 1
        let accessoryRows: CGFloat = usesStackedAccessoryControls(width: width) ? 1 : 0
        return minimumHeight + (transportRows + accessoryRows) * (controlBarMinimumHeight + 6)
    }

    public static func height(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let minimum = minimumHeight(width: width)
        return min(max(minimum, width * 9 / 16), max(minimum, viewportHeight * 0.9))
    }
}

/// Reusable player chrome. Application-specific controls (sources, tracks,
/// subtitles, casting, etc.) are supplied in `accessories`.
@MainActor
public struct AdvancedVideoPlayerControls<Model: AdvancedVideoPlayerControlling, Accessories: View>: View {
    public let model: Model
    public let isFullscreen: Bool
    public var availableWidth: CGFloat
    private let accessories: (@escaping () -> Void) -> Accessories
    @State private var controlsVisible = true
    @State private var menuPresented = false
    @State private var autoHide = ControlsAutoHide()

    public init(
        model: Model,
        isFullscreen: Bool,
        availableWidth: CGFloat = .infinity,
        @ViewBuilder accessories: @escaping (@escaping () -> Void) -> Accessories
    ) {
        self.model = model
        self.isFullscreen = isFullscreen
        self.availableWidth = availableWidth
        self.accessories = accessories
    }

    public var body: some View {
        let showingControls = controlsVisible || !model.isPlaying || model.waitingReason != nil
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { interacted() }.remoteNonFocusable()
            bars
                .opacity(showingControls ? 1 : 0)
                .allowsHitTesting(showingControls)
                .accessibilityHidden(!showingControls)
                .environment(\.playerMenuPresentationChanged, menuPresentationChanged)
            if !showingControls { RemoteRevealTarget { interacted() } }
            if let reason = model.waitingReason {
                // Playback that should advance but does not: say so, and why.
                VStack(spacing: 8) {
                    ProgressView()
                    Text(reason).font(.callout)
                }
                .foregroundStyle(Color.white)
                .padding(12)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
        }
        .onRemoteMove { interacted() }
        .onContinuousHover { if case .active = $0 { interacted() } }
        .remoteFocusScope()
        .task { interacted() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { interacted() }
            else { autoHide.task?.cancel(); controlsVisible = true }
        }
    }

    private var bars: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                if isFullscreen && !AdvancedVideoPlayerLayout.usesStackedTransport(width: availableWidth) {
                    Text(model.title).font(.headline)
                }
                Spacer()
                accessories(interacted).disabled(!model.isMediaReady)
            }
            .remoteFocusSection().foregroundStyle(Color.white)
            .frame(minHeight: AdvancedVideoPlayerLayout.controlBarMinimumHeight)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 8)

            Spacer().frame(minHeight: AdvancedVideoPlayerLayout.minimumBarSeparation, maxHeight: .infinity)
            transport.disabled(!model.isMediaReady).remoteFocusSection().foregroundStyle(Color.white)
                .frame(minHeight: AdvancedVideoPlayerLayout.controlBarMinimumHeight)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 8)
        }.padding(.vertical, 8)
    }

    private var transport: some View {
        VStack(spacing: 6) {
            timeline.frame(minHeight: AdvancedVideoPlayerLayout.controlBarMinimumHeight)
            if AdvancedVideoPlayerLayout.usesStackedTransport(width: availableWidth) {
                HStack(spacing: 14) { primaryButtons }.frame(minHeight: AdvancedVideoPlayerLayout.controlBarMinimumHeight)
                HStack(spacing: 14) { secondaryButtons }.frame(minHeight: AdvancedVideoPlayerLayout.controlBarMinimumHeight)
            } else {
                HStack(spacing: 14) { primaryButtons; Spacer(); secondaryButtons }
                    .frame(minHeight: AdvancedVideoPlayerLayout.controlBarMinimumHeight)
            }
        }
    }

    /// The seek bar (chapters, pipeline lanes, flagged regions, live window),
    /// with its own time labels.
    @ViewBuilder private var timeline: some View {
        let content = model.scrubberContent
        if content.end > 0 {
            MediaScrubber(
                content: content,
                value: min(model.playbackTime, content.end),
                onScrub: { _ in interacted() },
                onScrubEnded: { interacted(); model.seek(to: $0) },
                onJumpToLive: content.isLive ? { interacted(); model.jumpToLive() } : nil
            )
            .frame(minWidth: 80, maxWidth: .infinity)
        } else {
            HStack { Text(timeLabel).font(.caption.monospacedDigit()); Spacer() }
        }
    }

    @ViewBuilder private var primaryButtons: some View {
        Button { interacted(); model.skip(by: -10) } label: { Image(systemName: "gobackward.10").accessibilityLabel("Back 10 seconds") }
        Button { interacted(); model.togglePlayback() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        }
        .remotePrefersDefaultFocus(isFullscreen)
        Button { interacted(); model.skip(by: 10) } label: { Image(systemName: "goforward.10").accessibilityLabel("Forward 10 seconds") }
    }

    @ViewBuilder private var secondaryButtons: some View {
        switch model.pictureInPictureState {
        case .unsupported:
            EmptyView()
        case .starting, .stopping:
            // Changing: an indeterminate spinner in place of the button until it settles.
            ProgressView().accessibilityLabel("Picture in Picture is changing")
        case .active:
            Button { interacted(); model.stopPictureInPicture() } label: {
                Image(systemName: "pip.exit").accessibilityLabel("Exit Picture in Picture")
            }
        case .possible, .unavailable:
            Button { interacted(); model.startPictureInPicture() } label: {
                Image(systemName: "pip.enter").accessibilityLabel("Picture in Picture")
            }
            .disabled(model.pictureInPictureState == .unavailable)
        }
        Button { interacted(); model.toggleFullscreen() } label: {
            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .accessibilityLabel(isFullscreen ? "Exit Full Screen" : "Enter Full Screen")
        }
        PlayerMenu {
            Text(model.playbackRate == 1 ? "Speed" : "\(model.playbackRate.formatted())×").foregroundStyle(.white)
        } content: {
            ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                CheckableMenuItem(rate == 1 ? "Normal" : "\(rate.formatted())×",
                               state: rate == model.playbackRate ? .checked : .unchecked) {
                    interacted(); model.setPlaybackRate(rate)
                }
            }
        }
    }

    private var timeLabel: String {
        let seconds = max(0, Int(model.playbackTime)); return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func interacted() {
        // Continuous pointer motion can fire many times before a click. Avoid
        // invalidating the control subtree when it is already visible: GTK
        // otherwise replaces the button currently under the pointer, so the
        // subsequent release is delivered to a widget that no longer exists.
        if !controlsVisible { controlsVisible = true }
        autoHide.task?.cancel()
        guard model.isPlaying, !menuPresented else { return }
        autoHide.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.isPlaying else { return }
            controlsVisible = false
        }
    }

    private func menuPresentationChanged(_ presented: Bool) {
        menuPresented = presented
        if presented {
            controlsVisible = true
            autoHide.task?.cancel()
        } else {
            interacted()
        }
    }
}

/// The player timeline's slider on every platform. tvOS uses an explicit
/// focus/adjust mode for the Siri Remote; pointer and touch platforms retain
/// continuous native slider interaction behind the same component API.
@MainActor
public struct AdvancedVideoPlayerSlider: View {
    public let value: Double
    public let range: ClosedRange<Double>
    public let onChange: (Double) -> Void

    public init(value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
        self.value = value
        self.range = range
        self.onChange = onChange
    }

    @ViewBuilder
    public var body: some View {
        ScrubSlider(value: value, range: range, onChange: onChange)
    }
}

@MainActor private final class ControlsAutoHide {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}
