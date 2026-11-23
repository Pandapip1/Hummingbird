import SwiftOpenUI

private struct PlayerMenuPresentationChangedKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var playerMenuPresentationChanged: @MainActor @Sendable (Bool) -> Void {
        get { self[PlayerMenuPresentationChangedKey.self] }
        set { self[PlayerMenuPresentationChangedKey.self] = newValue }
    }
}

@MainActor
struct PlayerMenu<Label: View, Content: View>: View {
    @Environment(\.playerMenuPresentationChanged) private var presentationChanged
    /// The current choice, read with the menu's name ("Quality, 1080p").
    var value: String = ""
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Every dropdown over video is its own glass element (menus keep
        // CheckableMenuItem's left column inside).
        // The glass is part of the menu's label, so all of it opens the menu.
        PresentationMenu(onPresentationChange: presentationChanged, content: content) {
            label().playerHitTarget()
        }
        .accessibilityValue(value)
    }
}

/// An opt-in source/quality selector. The option type remains application-defined,
/// allowing URLs, DRM metadata, request modifiers, and similar policy to stay outside the kit.
@MainActor
public struct VideoSourceControl<Option: Identifiable>: View where Option.ID: Hashable {
    public let title: String
    public let options: [Option]
    public let selectedID: Option.ID?
    /// A choice the player is switching to; the checkmark stays on `selectedID` until it is confirmed.
    public let pendingID: Option.ID?
    private let label: (Option) -> String
    private let select: (Option) -> Void
    private let interacted: () -> Void

    public init(
        title: String = "Video",
        options: [Option],
        selectedID: Option.ID?,
        pendingID: Option.ID? = nil,
        label: @escaping (Option) -> String,
        onSelect: @escaping (Option) -> Void,
        interacted: @escaping () -> Void = {}
    ) {
        self.title = title
        self.options = options
        self.selectedID = selectedID
        self.pendingID = pendingID
        self.label = label
        self.select = onSelect
        self.interacted = interacted
    }

    public var body: some View {
        if !options.isEmpty {
            PlayerMenu(value: options.first { $0.id == pendingID }.map { "switching to \(label($0))" }
                        ?? options.first { $0.id == selectedID }.map(label) ?? "") {
                Text(title)
            } content: {
                ForEach(options) { option in
                    CheckableMenuItem(label(option), state: option.id == pendingID ? .pending : option.id == selectedID ? .checked : .unchecked) {
                        interacted(); select(option)
                    }
                }
            }
        }
    }
}

/// An opt-in embedded media-track selector for video, audio, or subtitles.
@MainActor
public struct MediaTrackControl: View {
    public let title: String
    public let tracks: [MediaTrack]
    public let selectedID: String?
    public let fallbackLabel: String
    private let select: (MediaTrack) -> Void
    private let interacted: () -> Void

    public init(
        title: String,
        tracks: [MediaTrack],
        selectedID: String?,
        fallbackLabel: String,
        onSelect: @escaping (MediaTrack) -> Void,
        interacted: @escaping () -> Void = {}
    ) {
        self.title = title
        self.tracks = tracks
        self.selectedID = selectedID
        self.fallbackLabel = fallbackLabel
        self.select = onSelect
        self.interacted = interacted
    }

    public var body: some View {
        if !tracks.isEmpty {
            PlayerMenu(value: tracks.first { $0.id == selectedID }.map { $0.menuTitle(fallback: fallbackLabel) } ?? "") {
                Text(title)
            } content: {
                ForEach(tracks, id: \.id) { track in
                    CheckableMenuItem(track.menuTitle(fallback: fallbackLabel),
                                   state: track.id == selectedID ? .checked : .unchecked) {
                        interacted(); select(track)
                    }
                }
            }
        }
    }
}

/// A generic external subtitle item suitable for feeds, local files, or services.
public struct SubtitleOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Opt-in subtitle selection supporting both backend-provided tracks and external subtitles.
/// Caption appearance controls can be injected into the same menu using `appearanceControls`.
@MainActor
public struct SubtitleControl<AppearanceControls: View>: View {
    public let embedded: [MediaTrack]
    public let external: [SubtitleOption]
    public let selectedEmbeddedID: String?
    public let selectedExternalID: SubtitleOption.ID?
    /// An external subtitle still loading; the checkmark stays on the current choice.
    public let pendingExternalID: SubtitleOption.ID?
    private let selectEmbedded: (MediaTrack) -> Void
    private let selectExternal: (SubtitleOption?) -> Void
    private let interacted: () -> Void
    private let appearanceControls: () -> AppearanceControls

    public init(
        embedded: [MediaTrack],
        external: [SubtitleOption],
        selectedEmbeddedID: String?,
        selectedExternalID: SubtitleOption.ID?,
        pendingExternalID: SubtitleOption.ID? = nil,
        onSelectEmbedded: @escaping (MediaTrack) -> Void,
        onSelectExternal: @escaping (SubtitleOption?) -> Void,
        interacted: @escaping () -> Void = {},
        @ViewBuilder appearanceControls: @escaping () -> AppearanceControls
    ) {
        self.embedded = embedded
        self.external = external
        self.selectedEmbeddedID = selectedEmbeddedID
        self.selectedExternalID = selectedExternalID
        self.pendingExternalID = pendingExternalID
        self.selectEmbedded = onSelectEmbedded
        self.selectExternal = onSelectExternal
        self.interacted = interacted
        self.appearanceControls = appearanceControls
    }

    public var body: some View {
        if !embedded.isEmpty || !external.isEmpty {
            PlayerMenu(value: external.first { $0.id == selectedExternalID }?.name
                        ?? embedded.first { $0.id == selectedEmbeddedID }.map { $0.menuTitle(fallback: "Embedded") } ?? "Off") {
                Text("Subtitles")
            } content: {
                CheckableMenuItem("Off", state: selectedEmbeddedID == nil && selectedExternalID == nil ? .checked : .unchecked) {
                    interacted(); selectExternal(nil)
                }
                ForEach(embedded, id: \.id) { track in
                    CheckableMenuItem(track.menuTitle(fallback: "Embedded"),
                                   state: selectedEmbeddedID == track.id ? .checked : .unchecked) {
                        interacted(); selectEmbedded(track)
                    }
                }
                ForEach(external) { subtitle in
                    CheckableMenuItem(subtitle.name, state: pendingExternalID == subtitle.id ? .pending : selectedExternalID == subtitle.id ? .checked : .unchecked) {
                        interacted(); selectExternal(subtitle)
                    }
                }
                appearanceControls()
            }
        }
    }
}

public extension SubtitleControl where AppearanceControls == EmptyView {
    init(
        embedded: [MediaTrack], external: [SubtitleOption],
        selectedEmbeddedID: String?, selectedExternalID: SubtitleOption.ID?,
        onSelectEmbedded: @escaping (MediaTrack) -> Void,
        onSelectExternal: @escaping (SubtitleOption?) -> Void,
        interacted: @escaping () -> Void = {}
    ) {
        self.init(embedded: embedded, external: external,
                  selectedEmbeddedID: selectedEmbeddedID, selectedExternalID: selectedExternalID,
                  onSelectEmbedded: onSelectEmbedded, onSelectExternal: onSelectExternal,
                  interacted: interacted) { EmptyView() }
    }
}

/// The smallest control over the video, glass included (Human Interface
/// Guidelines: 44 × 44 pt). UI tests check every player control against it.
public enum PlayerHitTarget {
    public static let minimum: Double = 44
}

extension View {
    /// A control's label on its glass, at least `PlayerHitTarget.minimum`
    /// in each direction, all of it taking touches. Used inside the label so
    /// the glass around the icon is part of the button, not decoration
    /// outside it.
    func playerHitTarget() -> some View {
        frame(minWidth: 24, minHeight: 28)
            .playerControlGlass()
            .frame(minWidth: PlayerHitTarget.minimum, minHeight: PlayerHitTarget.minimum)
            .contentShape(Capsule())
    }
}

/// An icon control over the video: at least 44 × 44 pt with its glass, the
/// whole glass taking touches, named on the button itself (so VoiceOver and
/// UI tests see the full target, not the icon).
@MainActor
struct PlayerIconButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    init(_ label: String, systemImage: String, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).playerHitTarget()
        }
        .accessibilityLabel(label)
    }
}
