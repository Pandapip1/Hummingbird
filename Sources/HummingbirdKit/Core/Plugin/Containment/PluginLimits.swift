import Foundation

/// The bounds that keep one plugin from exhausting the app: time, memory it
/// can make the host hold, output it can hand the UI, network use. Every
/// bound fails only the call (or plugin) that crossed it, with a visible error.
/// See Documentation/PluginSecurity.md for the reasoning behind each value.
enum PluginLimits {
    // MARK: time

    /// A synchronous plugin call (including the blocking HTTP it does).
    static let callTimeout: TimeInterval = 60
    /// `enable()` may fetch a player script or log in; it gets longer.
    static let enableTimeout: TimeInterval = 90
    /// A request modifier sits in front of every media range request.
    static let requestModifierTimeout: TimeInterval = 10
    /// One `bridge.sleep`; the call deadline still applies.
    static let maximumSleep: TimeInterval = 30
    /// Contexts of one plugin that stopped responding (still spinning in a
    /// script) before the plugin is suspended until the user retries.
    static let maximumHungWorkers = 2

    // MARK: concurrency

    /// JavaScript contexts per plugin that serve calls in parallel.
    static let maximumWorkers = 3
    /// Pending timers per context.
    static let maximumTimers = 256

    // MARK: network

    static let maximumConcurrentConnections = 24
    static let maximumConcurrentRequests = 12
    static let maximumBatchRequests = 64
    /// Requests per second, sustained, with a burst allowance.
    static let requestsPerSecond: Double = 30
    static let requestBurst: Double = 120
    static let maximumRequestBodyBytes = 16 * 1024 * 1024
    static let maximumResponseBodyBytes = 48 * 1024 * 1024
    static let maximumHeaderCount = 64
    static let maximumHeaderValueBytes = 16 * 1024

    // MARK: output

    /// The JSON text of one call's result.
    static let maximumResultBytes = 32 * 1024 * 1024
    /// Items in one page of results.
    static let maximumPageItems = 500
    /// Pages one pager may produce before the host stops asking.
    static let maximumPages = 200
    static let maximumTitleLength = 1_000
    static let maximumTextLength = 100_000
    static let maximumURLLength = 8_192
    static let maximumListLength = 1_000

    // MARK: host-side objects a script can make the host keep

    static let maximumDOMNodes = 200_000
    static let maximumDOMInputBytes = 16 * 1024 * 1024
    static let maximumUtilityInputBytes = 64 * 1024 * 1024

    // MARK: UI

    static let maximumToastLength = 200
    /// Toasts per plugin per minute.
    static let toastsPerMinute = 6
    static let maximumLogLineBytes = 8 * 1024
    /// Log lines per plugin per second before lines are dropped.
    static let logLinesPerSecond = 200
}

/// A token bucket: `rate` per second, holding at most `burst`.
struct TokenBucket: Sendable {
    let rate: Double
    let burst: Double
    private var tokens: Double
    private var last: Date

    init(rate: Double, burst: Double, now: Date = Date()) {
        self.rate = rate
        self.burst = burst
        tokens = burst
        last = now
    }

    /// Takes one token; returns how long to wait first (0 when one is available).
    mutating func take(now: Date = Date()) -> TimeInterval {
        tokens = min(burst, tokens + max(0, now.timeIntervalSince(last)) * rate)
        last = now
        tokens -= 1
        return tokens >= 0 ? 0 : -tokens / rate
    }

    /// Takes one token only if available now.
    mutating func tryTake(now: Date = Date()) -> Bool {
        tokens = min(burst, tokens + max(0, now.timeIntervalSince(last)) * rate)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
