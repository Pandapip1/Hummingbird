import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

// SwiftUI adds these IndexSet-based edits to arrays; the portable core needs them where SwiftUI is absent.
#if !canImport(SwiftUI) || BACKEND_GTK
extension RangeReplaceableCollection where Self: MutableCollection, Index == Int {
    mutating func remove(atOffsets offsets: IndexSet) {
        for i in offsets.sorted(by: >) { remove(at: i) }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[$0] }
        let before = source.filter { $0 < destination }.count
        remove(atOffsets: source)
        insert(contentsOf: moving, at: destination - before)
    }
}
#endif
