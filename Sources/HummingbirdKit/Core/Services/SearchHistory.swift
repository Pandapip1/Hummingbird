import Foundation
import Observation

@MainActor
@Observable
final class SearchHistory {
    private(set) var queries: [String]
    @ObservationIgnored private let save: ([String]) -> Void
    private let limit: Int

    init(limit: Int = 30,
         load: () -> [String] = { Storage.load([String].self, name: "search_history") ?? [] },
         save: @escaping ([String]) -> Void = { Storage.save($0, name: "search_history") }) {
        self.limit = max(1, limit)
        self.save = save
        queries = Array(load().prefix(max(1, limit)))
    }

    func record(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        queries.removeAll { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }
        queries.insert(value, at: 0)
        if queries.count > limit { queries.removeLast(queries.count - limit) }
        save(queries)
    }

    func remove(_ query: String) {
        queries.removeAll { $0 == query }
        save(queries)
    }

    func clear() {
        queries = []
        save(queries)
    }
}
