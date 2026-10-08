import SwiftOpenUI

public enum AdvancedVideoPlayerLayout {
    public static let controlBarMinimumHeight: CGFloat = 44
    public static let minimumBarSeparation: CGFloat = 24
    public static let minimumHeight = 2 * (controlBarMinimumHeight + 2 * 9) + 2 * 8 + 2 * 6 + minimumBarSeparation

    public static func usesStackedTransport(width: CGFloat) -> Bool { width < 600 }
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
    @State private var autoHide = ControlsAutoHide()
    @Namespace private var focusNamespace

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
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { interacted() }.modifier(NonFocusable())
            #if os(tvOS)
            if controlsVisible || !model.isPlaying { bars.onMoveCommand { _ in interacted() } }
            else { hiddenFocusTarget }
            #else
            if controlsVisible || !model.isPlaying { bars }
            #endif
        }
        .onContinuousHover { if case .active = $0 { interacted() } }
        #if os(tvOS)
        .focusScope(focusNamespace)
        #endif
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
                accessories(interacted)
            }
            .modifier(FocusSection()).foregroundStyle(Color.white)
            .frame(minHeight: AdvancedVideoPlayerLayout.controlBarMinimumHeight)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 8)

            Spacer().frame(minHeight: AdvancedVideoPlayerLayout.minimumBarSeparation, maxHeight: .infinity)
            transport.modifier(FocusSection()).foregroundStyle(Color.white)
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

    private var timeline: some View {
        HStack(spacing: 14) {
            Text(timeLabel).font(.caption.monospacedDigit())
            if model.duration > 0 {
                #if os(tvOS)
                ProgressView(value: min(model.playbackTime, model.duration), total: model.duration).frame(minWidth: 80, maxWidth: .infinity)
                #else
                Slider(value: Binding(get: { min(model.playbackTime, model.duration) }, set: { interacted(); model.seek(to: $0) }),
                       in: 0...model.duration, onEditingChanged: { _ in interacted() }).frame(minWidth: 80, maxWidth: .infinity)
                #endif
            } else { Spacer() }
        }
    }

    @ViewBuilder private var primaryButtons: some View {
        Button { interacted(); model.skip(by: -10) } label: { Image(systemName: "gobackward.10").accessibilityLabel("Back 10 seconds") }
        Button { interacted(); model.togglePlayback() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        }
        #if os(tvOS)
        .prefersDefaultFocus(isFullscreen, in: focusNamespace)
        #endif
        Button { interacted(); model.skip(by: 10) } label: { Image(systemName: "goforward.10").accessibilityLabel("Forward 10 seconds") }
    }

    @ViewBuilder private var secondaryButtons: some View {
        if model.pictureInPictureSupported {
            Button { interacted(); model.startPictureInPicture() } label: { Image(systemName: "pip.enter").accessibilityLabel("Picture in Picture") }
        }
        Button { interacted(); model.toggleFullscreen() } label: {
            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .accessibilityLabel(isFullscreen ? "Exit Full Screen" : "Enter Full Screen")
        }
        Menu {
            ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                Button { interacted(); model.setPlaybackRate(rate) } label: {
                    let label = rate == 1 ? "Normal" : "\(rate.formatted())×"
                    if rate == model.playbackRate { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: { Text(model.playbackRate == 1 ? "Speed" : "\(model.playbackRate.formatted())×").foregroundStyle(.white) }
    }

    #if os(tvOS)
    private var hiddenFocusTarget: some View {
        Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable().focusEffectDisabled().accessibilityLabel("Show playback controls")
            .onTapGesture { interacted() }.onMoveCommand { _ in interacted() }
    }
    #endif

    private var timeLabel: String {
        let seconds = max(0, Int(model.playbackTime)); return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func interacted() {
        controlsVisible = true
        autoHide.task?.cancel()
        guard model.isPlaying else { return }
        autoHide.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.isPlaying else { return }
            controlsVisible = false
        }
    }
}

private struct FocusSection: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(tvOS)
        content.focusSection()
        #else
        content
        #endif
    }
}

private struct NonFocusable: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(tvOS)
        content.focusable(false)
        #else
        content
        #endif
    }
}

@MainActor private final class ControlsAutoHide {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}
