import SwiftOpenUI
import Foundation
#if os(tvOS)
import UIKit
#endif

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
    #if os(tvOS)
    @Namespace private var focusNamespace
    #endif

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
        let showingControls = controlsVisible || !model.isPlaying
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { interacted() }.modifier(NonFocusable())
            bars
                .opacity(showingControls ? 1 : 0)
                .allowsHitTesting(showingControls)
                .accessibilityHidden(!showingControls)
                .environment(\.playerMenuPresentationChanged, menuPresentationChanged)
            #if os(tvOS)
            if !showingControls { hiddenFocusTarget }
            #endif
        }
        #if os(tvOS)
        .onMoveCommand { _ in interacted() }
        #endif
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
                AdvancedVideoPlayerSlider(
                    value: min(model.playbackTime, model.duration),
                    range: 0...model.duration,
                    onChange: { interacted(); model.seek(to: $0) }
                )
                .frame(minWidth: 80, maxWidth: .infinity)
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
        PlayerMenu {
            Text(model.playbackRate == 1 ? "Speed" : "\(model.playbackRate.formatted())×").foregroundStyle(.white)
        } content: {
            ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                Button { interacted(); model.setPlaybackRate(rate) } label: {
                    let label = rate == 1 ? "Normal" : "\(rate.formatted())×"
                    if rate == model.playbackRate { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        }
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
        #if os(tvOS)
        TVRemoteSlider(value: value, range: range, onChange: onChange)
        #else
        Slider(value: Binding(get: { value }, set: { newValue in onChange(newValue) }), in: range)
        #endif
    }
}

#if os(tvOS)
/// A focusable slider for the Siri Remote. Select enters adjustment mode,
/// directional presses seek while selected, and Select again releases focus
/// movement so the user can navigate to the surrounding player controls.
@MainActor
private struct TVRemoteSlider: UIViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    func makeUIView(context: Context) -> TVRemoteSliderControl {
        TVRemoteSliderControl()
    }

    func updateUIView(_ control: TVRemoteSliderControl, context: Context) {
        control.update(value: value, range: range, onChange: onChange)
    }
}

@MainActor
private final class TVRemoteSliderControl: UIControl {
    private let progress = UIProgressView(progressViewStyle: .default)
    private var value: Double = 0
    private var range: ClosedRange<Double> = 0...1
    private var onChange: ((Double) -> Void)?
    private var adjustmentStartValue: Double?
    private var isCancellingWithMenu = false
    private var isAdjusting = false { didSet { refreshAppearance() } }

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "playback-seek-control"
        accessibilityLabel = "Playback position"
        accessibilityTraits = [.adjustable]
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        layer.cornerRadius = 12
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
        self.value = value
        self.range = range
        self.onChange = onChange
        let length = range.upperBound - range.lowerBound
        progress.progress = length > 0 ? Float((value - range.lowerBound) / length) : 0
        accessibilityValue = "\(time(value)) of \(time(range.upperBound))\(isAdjusting ? ", adjusting" : "")"
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isAdjusting, presses.contains(where: { $0.type == .menu }) {
            if let adjustmentStartValue { adjust(to: adjustmentStartValue) }
            adjustmentStartValue = nil
            isAdjusting = false
            isCancellingWithMenu = true
            return
        }
        guard isAdjusting, let type = presses.first?.type else {
            super.pressesBegan(presses, with: event)
            return
        }
        switch type {
        case .leftArrow: adjust(by: -step)
        case .rightArrow: adjust(by: step)
        default: super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isCancellingWithMenu, presses.contains(where: { $0.type == .menu }) {
            isCancellingWithMenu = false
            return
        }
        if presses.contains(where: { $0.type == .select }) {
            if isAdjusting {
                adjustmentStartValue = nil
                isAdjusting = false
            } else {
                adjustmentStartValue = value
                isAdjusting = true
            }
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if !isFocused { isAdjusting = false }
        coordinator.addCoordinatedAnimations { self.refreshAppearance() }
    }

    override func accessibilityIncrement() { adjust(by: step) }
    override func accessibilityDecrement() { adjust(by: -step) }

    private var step: Double { min(30, max(5, (range.upperBound - range.lowerBound) / 100)) }

    private func adjust(by delta: Double) {
        adjust(to: value + delta)
    }

    private func adjust(to proposedValue: Double) {
        let target = min(max(proposedValue, range.lowerBound), range.upperBound)
        value = target
        onChange?(target)
        update(value: target, range: range, onChange: onChange ?? { _ in })
    }

    private func refreshAppearance() {
        progress.progressTintColor = isAdjusting ? tintColor : .white
        backgroundColor = isFocused ? UIColor.white.withAlphaComponent(0.18) : .clear
        transform = isFocused ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
        accessibilityValue = "\(time(value)) of \(time(range.upperBound))\(isAdjusting ? ", adjusting" : "")"
    }

    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif

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
