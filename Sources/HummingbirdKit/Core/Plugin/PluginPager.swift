import Foundation

/// An element that may fail to decode without sinking the page it arrived in.
struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct PagerPayload<Item: Decodable & Sendable>: Decodable, Sendable {
    var pager: Int
    var results: [Lossy<Item>]
    var hasMore: Bool
    var nextRequest: Int?
}

/// Wraps a pager object that lives inside a plugin runtime. `next()` asks the plugin for the following page; the
/// plugin may mutate itself or return a fresh pager, either way the runtime swaps the handle's contents.
///
/// Every page is contained for the plugin that produced it (`PluginOutput`), holds at most
/// `PluginLimits.maximumPageItems` items, and a pager ends after `PluginLimits.maximumPages` pages however
/// often the plugin claims there is more, so an endless pager cannot keep the app fetching.
final class PluginPager<Item: PluginOutput>: @unchecked Sendable {
    let runtime: PluginRuntime
    let initial: [Item]
    private let handle: Int
    private(set) var hasMore: Bool
    private(set) var nextRequest: Int?
    private(set) var pagesRead = 1

    init(runtime: PluginRuntime, payload: PagerPayload<Item>) {
        self.runtime = runtime
        self.handle = payload.pager
        self.initial = Self.contain(payload.results, context: runtime.outputContext)
        self.hasMore = payload.hasMore && payload.pager != 0
        self.nextRequest = payload.nextRequest.map { min(max($0, 0), 3_600_000) }
    }

    static func contain(_ results: [Lossy<Item>], context: PluginOutputContext) -> [Item] {
        results.prefix(PluginLimits.maximumPageItems).compactMap { lossy in
            guard var item = lossy.value else { return nil }
            item.contain(context)
            return item
        }
    }

    func next() async throws -> [Item] {
        guard hasMore else { return [] }
        guard pagesRead < PluginLimits.maximumPages else {
            hasMore = false
            return []
        }
        let data = try await runtime.nextPageRaw(handle: handle)
        let payload = try PluginRuntime.decodeEnvelope(PagerPayload<Item>.self, from: data)
        pagesRead += 1
        hasMore = payload.hasMore && pagesRead < PluginLimits.maximumPages
        nextRequest = payload.nextRequest.map { min(max($0, 0), 3_600_000) }
        return Self.contain(payload.results, context: runtime.outputContext)
    }
}
