import SwiftOpenUI

/// An opt-in source/quality selector. The option type remains application-defined,
/// allowing URLs, DRM metadata, request modifiers, and similar policy to stay outside the kit.
@MainActor
public struct VideoSourceControl<Option: Identifiable>: View where Option.ID: Hashable {
    public let title: String
    public let options: [Option]
    public let selectedID: Option.ID?
    private let label: (Option) -> String
    private let select: (Option) -> Void
    private let interacted: () -> Void

    public init(
        title: String = "Video",
        options: [Option],
        selectedID: Option.ID?,
        label: @escaping (Option) -> String,
        onSelect: @escaping (Option) -> Void,
        interacted: @escaping () -> Void = {}
    ) {
        self.title = title
        self.options = options
        self.selectedID = selectedID
        self.label = label
        self.select = onSelect
        self.interacted = interacted
    }

    public var body: some View {
        if !options.isEmpty {
            Menu {
                ForEach(options) { option in
                    Button { interacted(); select(option) } label: {
                        if option.id == selectedID { Label(label(option), systemImage: "checkmark") }
                        else { Text(label(option)) }
                    }
                }
            } label: { Text(title) }
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
            Menu {
                ForEach(tracks, id: \.id) { track in
                    Button { interacted(); select(track) } label: {
                        let text = track.label ?? track.language ?? fallbackLabel
                        if track.id == selectedID { Label(text, systemImage: "checkmark") }
                        else { Text(text) }
                    }
                }
            } label: { Text(title) }
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
    private let selectEmbedded: (MediaTrack) -> Void
    private let selectExternal: (SubtitleOption?) -> Void
    private let interacted: () -> Void
    private let appearanceControls: () -> AppearanceControls

    public init(
        embedded: [MediaTrack],
        external: [SubtitleOption],
        selectedEmbeddedID: String?,
        selectedExternalID: SubtitleOption.ID?,
        onSelectEmbedded: @escaping (MediaTrack) -> Void,
        onSelectExternal: @escaping (SubtitleOption?) -> Void,
        interacted: @escaping () -> Void = {},
        @ViewBuilder appearanceControls: @escaping () -> AppearanceControls
    ) {
        self.embedded = embedded
        self.external = external
        self.selectedEmbeddedID = selectedEmbeddedID
        self.selectedExternalID = selectedExternalID
        self.selectEmbedded = onSelectEmbedded
        self.selectExternal = onSelectExternal
        self.interacted = interacted
        self.appearanceControls = appearanceControls
    }

    public var body: some View {
        if !embedded.isEmpty || !external.isEmpty {
            Menu {
                Button { interacted(); selectExternal(nil) } label: {
                    if selectedEmbeddedID == nil && selectedExternalID == nil { Label("Off", systemImage: "checkmark") }
                    else { Text("Off") }
                }
                ForEach(embedded, id: \.id) { track in
                    Button { interacted(); selectEmbedded(track) } label: {
                        let name = track.label ?? track.language ?? "Embedded"
                        if selectedEmbeddedID == track.id { Label(name, systemImage: "checkmark") }
                        else { Text(name) }
                    }
                }
                ForEach(external) { subtitle in
                    Button { interacted(); selectExternal(subtitle) } label: {
                        if selectedExternalID == subtitle.id { Label(subtitle.name, systemImage: "checkmark") }
                        else { Text(subtitle.name) }
                    }
                }
                appearanceControls()
            } label: { Text("Subtitles") }
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
