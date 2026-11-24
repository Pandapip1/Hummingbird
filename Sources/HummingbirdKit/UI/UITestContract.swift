/// Names the app and its UI tests share. The UI test targets compile this
/// file too (project.yml), so a scene or identifier that is renamed or
/// removed breaks the tests' build instead of failing them at run time.

/// One piece of UI shown on its own instead of the app
/// (`HUMMINGBIRD_DEBUG_SCENE`, see `DebugSceneSelection`).
enum DebugScene: String, CaseIterable, Sendable {
    /// A player with a generated clip, playing, that can go full screen.
    case playerFullscreen = "player-fullscreen"
    /// Generated WebM over the plugin media proxy (debug builds).
    case playerWebMDash = "player-webm-dash"
    /// The player controls over a model with a fixed position.
    case playerSeek = "player-seek"
    /// An install preview with many allowed URLs.
    case installPreview = "install-preview"

    static let environmentKey = "HUMMINGBIRD_DEBUG_SCENE"
}

/// Accessibility identifiers UI tests find elements by.
enum UITestIdentifier {
    static func installPreviewURL(_ index: Int) -> String { "install-preview-url-\(index)" }
}
