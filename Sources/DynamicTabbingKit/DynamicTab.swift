import Foundation
import Observation

/// A reusable browser-style tab with linear back/forward history.
///
/// `Page` is deliberately application-defined: it may be a URL, route enum,
/// document identifier, or any other value an application can render.
@MainActor
@Observable
public final class DynamicTab<Page>: Identifiable {
    public let id: UUID
    public let isPinned: Bool
    public private(set) var history: [Page]
    public private(set) var historyIndex: Int
    public var title: String

    @ObservationIgnored private let defaultTitle: @MainActor (Page) -> String

    public init(
        id: UUID = UUID(),
        isPinned: Bool = false,
        title: String = "New Tab",
        defaultTitle: @escaping @MainActor (Page) -> String = { _ in "New Tab" }
    ) {
        self.id = id
        self.isPinned = isPinned
        self.title = title
        self.history = []
        self.historyIndex = -1
        self.defaultTitle = defaultTitle
    }

    public var current: Page? {
        history.indices.contains(historyIndex) ? history[historyIndex] : nil
    }

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex < history.count - 1 }

    public func push(_ page: Page, title: String? = nil) {
        if historyIndex < history.count - 1 {
            history.removeLast(history.count - 1 - historyIndex)
        }
        history.append(page)
        historyIndex = history.count - 1
        self.title = title ?? defaultTitle(page)
    }

    public func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
    }

    public func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
    }

    public func reportTitle(_ title: String) {
        guard !title.isEmpty, current != nil else { return }
        self.title = title
    }
}

/// Owns an uncloseable pinned tab plus an ordered collection of ordinary tabs.
@MainActor
@Observable
public final class DynamicTabCollection<Page> {
    public let pinnedTab: DynamicTab<Page>
    public private(set) var tabs: [DynamicTab<Page>]
    public var selection: DynamicTab<Page>.ID

    @ObservationIgnored private let makeTab: @MainActor () -> DynamicTab<Page>

    public init(
        pinnedTab: DynamicTab<Page>,
        tabs: [DynamicTab<Page>] = [],
        makeTab: @escaping @MainActor () -> DynamicTab<Page>
    ) {
        self.pinnedTab = pinnedTab
        self.tabs = tabs
        self.selection = pinnedTab.id
        self.makeTab = makeTab
    }

    public var selectedTab: DynamicTab<Page> {
        tabs.first { $0.id == selection } ?? pinnedTab
    }

    @discardableResult
    public func open(_ page: Page, title: String? = nil) -> DynamicTab<Page> {
        let tab = makeTab()
        tab.push(page, title: title)
        tabs.append(tab)
        selection = tab.id
        return tab
    }

    @discardableResult
    public func openBlank() -> DynamicTab<Page> {
        let tab = makeTab()
        tabs.append(tab)
        selection = tab.id
        return tab
    }

    public func close(_ id: DynamicTab<Page>.ID) {
        guard id != pinnedTab.id,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        guard selection == id else { return }
        selection = tabs.indices.contains(index) ? tabs[index].id
            : (tabs.indices.contains(index - 1) ? tabs[index - 1].id : pinnedTab.id)
    }
}
