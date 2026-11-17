import SwiftOpenUI

private struct PlayerMenuPresentationChangedKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (Bool) -> Void = { _ in }
}

private struct PlayerMenuUsesSystemItemsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var playerMenuPresentationChanged: @MainActor @Sendable (Bool) -> Void {
        get { self[PlayerMenuPresentationChangedKey.self] }
        set { self[PlayerMenuPresentationChangedKey.self] = newValue }
    }
    /// True inside a system-drawn menu (SwiftUI `Menu` on macOS/tvOS), which
    /// reserves its own checkmark column for toggles.
    var playerMenuUsesSystemItems: Bool {
        get { self[PlayerMenuUsesSystemItemsKey.self] }
        set { self[PlayerMenuUsesSystemItemsKey.self] = newValue }
    }
}

@MainActor
struct PlayerMenu<Label: View, Content: View>: View {
    @Environment(\.playerMenuPresentationChanged) private var presentationChanged
    @State private var isPresented = false
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        Button { isPresented = true } label: { label() }
            .popover(isPresented: $isPresented) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { content() }
                        .buttonStyle(.plain)
                        .padding()
                }
                .onTapGesture { isPresented = false }
                .presentationCompactAdaptation(.popover)
            }
            .onChange(of: isPresented) { _, presented in presentationChanged(presented) }
            .onDisappear { if isPresented { presentationChanged(false) } }
        #elseif canImport(SwiftUI) && !BACKEND_GTK
        Menu(content: { content().environment(\.playerMenuUsesSystemItems, true) }, label: label)
        #else
        Menu(content: content, label: label)
        #endif
    }
}

/// What a choice in a player menu currently is.
public enum PlayerMenuItemState: Sendable, Equatable {
    case unselected
    /// The choice in effect.
    case selected
    /// Chosen, but not in effect until the player confirms it (no optimistic
    /// checkmark): the checkmark stays on the current choice meanwhile.
    case pending
}

/// One choice in a player menu. Every player menu uses it, so labels line up
/// in one column: a fixed leading column holds the checkmark (or the pending
/// spinner) and never shifts the text. In system-drawn menus the item is a
/// toggle, which the system gives its own reserved checkmark column; the
/// pending spinner then appears on the menu's label instead.
@MainActor
public struct PlayerMenuItem: View {
    @Environment(\.playerMenuUsesSystemItems) private var usesSystemItems
    public let title: String
    public let state: PlayerMenuItemState
    private let action: () -> Void

    public init(_ title: String, state: PlayerMenuItemState, action: @escaping () -> Void) {
        self.title = title
        self.state = state
        self.action = action
    }

    public var body: some View {
        if usesSystemItems {
            Toggle(title, isOn: Binding(get: { state == .selected }, set: { _ in if state == .unselected { action() } }))
        } else {
            Button(action: action) {
                HStack(spacing: 8) {
                    ZStack {
                        switch state {
                        case .selected: Image(systemName: "checkmark")
                        case .pending: ProgressView()
                        case .unselected: Color.clear
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(title)
                    Spacer(minLength: 0)
                }
            }
            .disabled(state == .pending)
        }
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
                HStack(spacing: 6) {
                    Text(title)
                    if pendingID != nil { ProgressView() }
                }
            } content: {
                ForEach(options) { option in
                    PlayerMenuItem(label(option), state: option.id == pendingID ? .pending : option.id == selectedID ? .selected : .unselected) {
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
                    PlayerMenuItem(track.label ?? track.language ?? fallbackLabel,
                                   state: track.id == selectedID ? .selected : .unselected) {
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
            PlayerMenu {
                Text("Subtitles")
            } content: {
                PlayerMenuItem("Off", state: selectedEmbeddedID == nil && selectedExternalID == nil ? .selected : .unselected) {
                    interacted(); selectExternal(nil)
                }
                ForEach(embedded, id: \.id) { track in
                    PlayerMenuItem(track.label ?? track.language ?? "Embedded",
                                   state: selectedEmbeddedID == track.id ? .selected : .unselected) {
                        interacted(); selectEmbedded(track)
                    }
                }
                ForEach(external) { subtitle in
                    PlayerMenuItem(subtitle.name, state: selectedExternalID == subtitle.id ? .selected : .unselected) {
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
