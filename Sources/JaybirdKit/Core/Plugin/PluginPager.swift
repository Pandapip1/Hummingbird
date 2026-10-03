import Foundation

/// An element that may fail to decode without sinking the page it arrived in.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct PagerPayload<Item: Decodable>: Decodable {
    var pager: Int
    var results: [Lossy<Item>]
    var hasMore: Bool
    var nextRequest: Int?
}

/// Wraps a pager object that lives inside a plugin runtime. `next()` asks the plugin for the following page; the
/// plugin may mutate itself or return a fresh pager, either way the runtime swaps the handle's contents.
final class PluginPager<Item: Decodable & Sendable>: @unchecked Sendable {
    let runtime: PluginRuntime
    let initial: [Item]
    private let handle: Int
    private(set) var hasMore: Bool
    private(set) var nextRequest: Int?

    init(runtime: PluginRuntime, payload: PagerPayload<Item>) {
        self.runtime = runtime
        self.handle = payload.pager
        self.initial = payload.results.compactMap { $0.value }
        self.hasMore = payload.hasMore && payload.pager != 0
        self.nextRequest = payload.nextRequest
    }

    func next() async throws -> [Item] {
        guard hasMore else { return [] }
        let data = try await runtime.nextPageRaw(handle: handle)
        let payload = try PluginRuntime.decode(PagerPayload<Item>.self, from: data)
        hasMore = payload.hasMore
        nextRequest = payload.nextRequest
        return payload.results.compactMap { $0.value }
    }
}
