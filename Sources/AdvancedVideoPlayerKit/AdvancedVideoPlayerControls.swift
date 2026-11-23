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
    /// VoiceOver or Switch Control: the controls never hide on a timer.
    @Environment(\.assistiveTechnologyState) private var assistiveTechnology
    /// Control rows and spacing grow with the text size.
    @ScaledMetric(relativeTo: .body) private var controlRowHeight: CGFloat = AdvancedVideoPlayerLayout.controlBarMinimumHeight
    @ScaledMetric(relativeTo: .body) private var buttonSpacing: CGFloat = 14

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
            || assistiveTechnology.keepsControlsVisible
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { interacted() }.remoteNonFocusable()
            bars
                .autoHiddenControls(!showingControls)
                // Hidden by the timer, the controls stay reachable by name and focus
                // (VoiceOver, Voice Control, Switch Control, keyboards).
                .environment(\.playerMenuPresentationChanged, menuPresentationChanged)
            if !showingControls { RemoteRevealTarget { interacted() } }
            keyCommands
            if let reason = model.waitingReason {
                // Playback that should advance but does not: say so, and why.
                PlayerControlGroup {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(reason).font(.callout)
                    }
                    .playerSurfaceGlass()
                }
                .allowsHitTesting(false)
                .accessibilityLabel(reason)
            }
        }
        .onRemoteMove { interacted() }
        .onContinuousHover { if case .active = $0 { interacted() } }
        .remoteFocusScope()
        .task { interacted() }
        .onAppear { model.controlsVisibilityChanged(showingControls) }
        .onChange(of: showingControls) { _, visible in model.controlsVisibilityChanged(visible) }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { interacted() }
            else { autoHide.task?.cancel(); controlsVisible = true }
        }
        .onChange(of: assistiveTechnology) { _, state in
            if state.keepsControlsVisible { autoHide.task?.cancel(); controlsVisible = true }
        }
    }

    /// Keyboard commands (where there is a keyboard): space play/pause, ←/→
    /// 10 s, ⇧←/⇧→ chapter, F full screen, C captions, [ and ] speed. Hidden from
    /// assistive technology: the visible controls carry the same actions.
    private var keyCommands: some View {
        let layout = ScrubberLayout(content: model.scrubberContent, width: 1)
        let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        let rateIndex = rates.firstIndex(of: model.playbackRate) ?? 3
        return ZStack {
            Button("") { interacted(); model.togglePlayback() }.playerKeyCommand(.space)
            Button("") { interacted(); model.skip(by: -10) }.playerKeyCommand(.leftArrow)
            Button("") { interacted(); model.skip(by: 10) }.playerKeyCommand(.rightArrow)
            Button("") {
                interacted()
                if let start = layout.previousChapterStart(before: model.playbackTime) { model.seek(to: start) }
            }.playerKeyCommand(.leftArrow, modifiers: .shift)
            Button("") {
                interacted()
                if let start = layout.nextChapterStart(after: model.playbackTime) { model.seek(to: start) }
            }.playerKeyCommand(.rightArrow, modifiers: .shift)
            Button("") { interacted(); model.toggleFullscreen() }.playerKeyCommand("f")
            Button("") { interacted(); model.toggleCaptions() }.playerKeyCommand("c")
            Button("") { interacted(); model.setPlaybackRate(rates[max(0, rateIndex - 1)]) }.playerKeyCommand("[")
            Button("") { interacted(); model.setPlaybackRate(rates[min(rates.count - 1, rateIndex + 1)]) }.playerKeyCommand("]")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .disabled(!model.isMediaReady)
    }

    private var bars: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                if isFullscreen && !AdvancedVideoPlayerLayout.usesStackedTransport(width: availableWidth) {
                    Text(model.title).font(.headline).playerTitleGlass()
                }
                Spacer()
                PlayerControlGroup {
                    HStack(spacing: 12) { accessories(interacted) }
                }
                .disabled(!model.isMediaReady)
            }
            .remoteFocusSection()
            .frame(minHeight: controlRowHeight)
            .padding(.horizontal, 8)

            Spacer().frame(minHeight: AdvancedVideoPlayerLayout.minimumBarSeparation, maxHeight: .infinity)
            PlayerControlGroup { transport }
                .disabled(!model.isMediaReady).remoteFocusSection()
                .frame(minHeight: controlRowHeight)
                .padding(.horizontal, 8)
        }.padding(.vertical, 8)
    }

    private var transport: some View {
        VStack(spacing: 6) {
            timeline.frame(minHeight: controlRowHeight)
            if AdvancedVideoPlayerLayout.usesStackedTransport(width: availableWidth) {
                HStack(spacing: buttonSpacing) { primaryButtons }.frame(minHeight: controlRowHeight)
                HStack(spacing: buttonSpacing) { secondaryButtons }.frame(minHeight: controlRowHeight)
            } else {
                HStack(spacing: buttonSpacing) { primaryButtons; Spacer(); secondaryButtons }
                    .frame(minHeight: controlRowHeight)
            }
        }
    }

    /// The seek bar (chapters, pipeline lanes, flagged regions, live window),
    /// with its own time labels.
    /// Its own view: only it observes the position (`PlaybackClock`), so the
    /// rest of the controls do not redraw as playback advances.
    private var timeline: some View {
        PlayerTimeline(model: model, clock: model.clock, interacted: interacted)
    }

    @ViewBuilder private var primaryButtons: some View {
        PlayerIconButton("Back 10 seconds", systemImage: "gobackward.10") { interacted(); model.skip(by: -10) }
        PlayerIconButton(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
            interacted(); model.togglePlayback()
        }
        .remotePrefersDefaultFocus(isFullscreen)
        PlayerIconButton("Forward 10 seconds", systemImage: "goforward.10") { interacted(); model.skip(by: 10) }
    }

    @ViewBuilder private var secondaryButtons: some View {
        switch model.pictureInPictureState {
        case .unsupported:
            EmptyView()
        case .starting, .stopping:
            // Changing: an indeterminate spinner in place of the button until it settles.
            ProgressView().accessibilityLabel("Picture in Picture is changing").playerControlGlass()
        case .active:
            PlayerIconButton("Exit Picture in Picture", systemImage: "pip.exit") { interacted(); model.stopPictureInPicture() }
        case .possible, .unavailable:
            PlayerIconButton("Picture in Picture", systemImage: "pip.enter") { interacted(); model.startPictureInPicture() }
            .disabled(model.pictureInPictureState == .unavailable)
        }
        PlayerIconButton(isFullscreen ? "Exit Full Screen" : "Enter Full Screen",
                         systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            interacted(); model.toggleFullscreen()
        }
        PlayerMenu(value: model.playbackRate == 1 ? "Normal" : "\(model.playbackRate.formatted()) times") {
            Text(model.playbackRate == 1 ? "Speed" : "\(model.playbackRate.formatted())×")
        } content: {
            ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                CheckableMenuItem(rate == 1 ? "Normal" : "\(rate.formatted())×",
                               state: rate == model.playbackRate ? .checked : .unchecked) {
                    interacted(); model.setPlaybackRate(rate)
                }
            }
        }
    }


    private func interacted() {
        // Continuous pointer motion can fire many times before a click. Avoid
        // invalidating the control subtree when it is already visible: GTK
        // otherwise replaces the button currently under the pointer, so the
        // subsequent release is delivered to a widget that no longer exists.
        if !controlsVisible { controlsVisible = true }
        autoHide.task?.cancel()
        guard model.isPlaying, !menuPresented, !assistiveTechnology.keepsControlsVisible else { return }
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

/// The seek bar and its time labels: the one part of the controls that
/// observes the position, so it alone redraws on every tick.
@MainActor
private struct PlayerTimeline<Model: AdvancedVideoPlayerControlling>: View {
    let model: Model
    let clock: PlaybackClock
    let interacted: () -> Void

    var body: some View {
        let content = model.scrubberContent
        if content.end > 0 {
            MediaScrubber(
                "Playback position",
                content: content,
                value: min(clock.time, content.end),
                onScrub: { _ in interacted() },
                onScrubEnded: { interacted(); model.seek(to: $0) },
                onJumpToLive: content.isLive ? { interacted(); model.jumpToLive() } : nil
            )
            .frame(minWidth: 80, maxWidth: .infinity)
            .playerSurfaceGlass()
        } else {
            HStack { Text(timeLabel).font(.caption.monospacedDigit()); Spacer() }.playerSurfaceGlass()
        }
    }

    private var timeLabel: String {
        let seconds = max(0, Int(clock.time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
