import Foundation

/// What kind of content a source carries, for age defaults.
enum SourceCategory: String, Codable, Sendable, CaseIterable {
    /// Open upload platforms (YouTube, Rumble, Odysee…): anyone can publish,
    /// so anything can appear.
    case generalVideo
    case music
    case podcasts
    case news
    case education
    case adult
    case unknown

    /// The minimum age a source of this category gets when the curated list
    /// gives none.
    var defaultMinimumAge: Int {
        switch self {
        case .generalVideo, .adult, .unknown: return 18
        case .news: return 13
        case .music, .podcasts: return 13
        case .education: return 0
        }
    }
}

/// How the app rates a source. Curated entries come from a reviewed list
/// (task 59 replaces the bundled placeholder); anything else is unlisted.
struct SourceClassification: Sendable, Equatable {
    var pluginID: String
    /// Whether the source is on the reviewed list, with the author key pinned.
    var isCurated: Bool
    var category: SourceCategory
    /// The rating assigned to this plugin in the curated database, as the
    /// youngest suitable age in years (0, 13, 16 or 18). nil: not rated yet.
    var explicitMinimumAge: Int?
    /// The rating in force: the plugin's own, else its category's default.
    var minimumAge: Int { explicitMinimumAge ?? category.defaultMinimumAge }
    /// Settings that raise the rating when set to certain values (YouTube:
    /// `allowAgeRestricted` = `true` makes it 18+). `minimumAge` is the
    /// rating with every one of them at its safe value.
    var settingRatings: [SettingRating] = []

    /// The safe value of every rated setting: the source's restricted mode.
    var restrictedModeSettings: [String: String] {
        Dictionary(settingRatings.map { ($0.setting, $0.safeValue) }) { first, _ in first }
    }

    /// The rating with `settings` (the plugin's stored values; missing ones
    /// count as safe, as the policy forces them when needed).
    func effectiveMinimumAge(settings: [String: String]) -> Int {
        settingRatings.reduce(minimumAge) { rating, condition in
            guard let value = settings[condition.setting], condition.values.contains(value) else { return rating }
            return max(rating, condition.minimumAge)
        }
    }

    static func unlisted(_ pluginID: String) -> Self {
        Self(pluginID: pluginID, isCurated: false, category: .unknown, explicitMinimumAge: nil)
    }
}

/// A plugin setting that raises a source's rating: when `setting` holds
/// one of `values`, the source is rated `minimumAge`. `safeValue` keeps it
/// at its base rating; the policy forces it when the user may not have the
/// higher rating.
struct SettingRating: Codable, Hashable, Sendable {
    var setting: String
    /// Values as the plugin stores them ("true", a dropdown index...).
    var values: [String]
    var minimumAge: Int
    var safeValue: String
}

/// Classifies sources. `CuratedSourceDatabase` (the reviewed list, with
/// pinned author keys and per-plugin ratings) implements this.
protocol SourceClassifier: Sendable {
    /// `config` is what the source declares about itself; implementations
    /// must not trust it for anything but matching (id, author key).
    func classification(for config: PluginConfig) -> SourceClassification
    /// The reviewed source's name when `config` claims its id without its
    /// pinned key (an impersonation, or a fork), else nil.
    func reviewedName(ofLookalike config: PluginConfig) -> String?
    /// Every reviewed source, for the discovery page.
    var reviewedEntries: [CuratedSourceEntry] { get }
}
