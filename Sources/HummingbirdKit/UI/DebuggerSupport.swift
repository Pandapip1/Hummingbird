import Foundation
import SwiftOpenUI

/// App state and actions for the debugger, replacing the old HTTP debug
/// server's probes and actions. Tools/lldb/hummingbird.lldb wraps these as
/// `hb` commands (`hb state`, `hb play`, `hb seek 60`, …); they can also be
/// called directly, e.g. `expr -l Swift -- HummingbirdDebug.state()`.
///
/// Run them while the process is stopped on the main thread (pause, or a
/// breakpoint in UI code): they touch main-actor state.
@MainActor
public enum HummingbirdDebug {
    private struct WeakModel {
        weak var model: AppModel?
    }

    private static var models: [WeakModel] = []
    /// The player of a standalone debug scene (`HUMMINGBIRD_DEBUG_SCENE=player`), when one is showing.
    static weak var standalonePlayer: PlayerModel?
    /// Set by the root view: its tab overview is view state.
    static var toggleTabOverviewAction: (@MainActor () -> Void)?

    /// Called by each window's `AppModel`.
    static func register(_ model: AppModel) {
        models.removeAll { $0.model == nil }
        models.append(WeakModel(model: model))
    }

    /// The most recently created window's model that is still alive.
    static var model: AppModel? { models.last(where: { $0.model != nil })?.model }

    /// The active tab's player.
    static var player: PlayerModel? { standalonePlayer ?? model?.activePlayerForDebug }

    /// What the debug server's `/state` used to report.
    public static func state() -> String {
        var lines: [String] = []
        if let model {
            lines.append(model.debugDescription)
            lines.append("windows: \(models.count(where: { $0.model != nil }))")
        } else {
            lines.append("no window")
        }
        if let player {
            lines.append(player.debugDescription)
        } else {
            lines.append("no player in the active tab")
        }
        if let focused = FocusDiagnostics.focusedItemDescription() {
            lines.append("focused: \(focused)")
        }
        return lines.joined(separator: "\n")
    }

    /// Installed plugins: id, version, enabled, script size and setting names.
    public static func plugins() -> String {
        guard let model else { return "no window" }
        let installed = model.plugins.installed
        guard !installed.isEmpty else { return "no plugins installed" }
        return installed.map(\.debugDescription).joined(separator: "\n")
    }

    public static func togglePlayback() { player?.togglePlayback() }
    public static func skip(by seconds: Double) { player?.skip(by: seconds) }
    public static func toggleFullscreen() { player?.toggleFullscreen() }
    public static func toggleTabOverview() { toggleTabOverviewAction?() }

    /// Opens content (a URL a plugin handles) in a new tab.
    public static func open(_ url: String) {
        model?.openInNewTab(.content(url), title: "Debug")
    }

    /// Where MetricKit reports are kept, newest first.
    public static func reports() -> String {
        guard let model else { return "no window" }
        let store = PerformanceReports.store(for: model.stores)
        let reports = store.reports()
        guard !reports.isEmpty else { return "no reports in \(store.directory.path)" }
        return reports.map(\.path).joined(separator: "\n")
    }
}

extension AppModel: @MainActor CustomDebugStringConvertible {
    /// The active tab and its route; routes can hold URLs, which is fine in a
    /// debugger on the developer's own process.
    var debugDescription: String {
        "AppModel(tabs: \(contentTabs.count), active: \(activeTab.title) \(activeTabID.uuidString.prefix(8)) at \(activeTab.current.map { String(describing: $0) } ?? "nothing"), plugins: \(plugins.installed.count))"
    }
}

extension PlayerModel: @MainActor CustomDebugStringConvertible {
    var debugDescription: String {
        var parts = [
            isPlaying ? "playing" : "paused",
            String(format: "%.1f/%.1fs", playbackTime, duration),
        ]
        if isPreparing { parts.append("preparing") }
        if isFullscreen { parts.append("fullscreen") }
        if let errorMessage { parts.append("error: \(errorMessage)") }
        return "PlayerModel(\(parts.joined(separator: ", ")))"
    }
}
