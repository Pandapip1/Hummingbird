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
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        PresentationMenu(onPresentationChange: presentationChanged, content: content, label: label)
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
            PlayerMenu {
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
            PlayerMenu {
                Text(title)
            } content: {
                ForEach(tracks, id: \.id) { track in
                    CheckableMenuItem(track.label ?? track.language ?? fallbackLabel,
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
            PlayerMenu {
                Text("Subtitles")
            } content: {
                CheckableMenuItem("Off", state: selectedEmbeddedID == nil && selectedExternalID == nil ? .checked : .unchecked) {
                    interacted(); selectExternal(nil)
                }
                ForEach(embedded, id: \.id) { track in
                    CheckableMenuItem(track.label ?? track.language ?? "Embedded",
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
