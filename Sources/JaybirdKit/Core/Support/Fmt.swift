import Foundation

enum Fmt {
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func count(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 10_000...: return String(format: "%.0fK", Double(n) / 1e3)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1e3)
        default: return "\(n)"
        }
    }

    #if canImport(Darwin)
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relative(_ date: Date) -> String { relativeFormatter.localizedString(for: date, relativeTo: Date()) }
    #else
    // RelativeDateTimeFormatter is not in Foundation on Linux, so this renders English text itself.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        let future = seconds < 0
        let s = abs(seconds)
        let units: [(Int, String)] = [(31_536_000, "year"), (2_592_000, "month"), (604_800, "week"), (86_400, "day"), (3_600, "hour"), (60, "minute")]
        guard let (size, name) = units.first(where: { s >= $0.0 }) else { return "now" }
        let n = s / size
        let text = "\(n) \(name)\(n == 1 ? "" : "s")"
        return future ? "in \(text)" : "\(text) ago"
    }
    #endif
}
