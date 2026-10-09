import Foundation
import SwiftOpenUI

/// Compact browser controls. On iOS the containing `TabView` presents these
/// through its native bottom-accessory area so they share the tab-bar chrome.
@MainActor
struct MobileBrowserToolbar: View {
    @Environment(AppModel.self) private var app
    @Binding var showingTabOverview: Bool

    var body: some View {
        HStack {
            Button { app.activeTab.goBack() } label: {
                tabBarButtonLabel { Image(systemName: "chevron.left") }
            }
                .disabled(!app.activeTab.canGoBack)
                .accessibilityLabel("Back")
            Button { app.activeTab.goForward() } label: {
                tabBarButtonLabel { Image(systemName: "chevron.right") }
            }
                .disabled(!app.activeTab.canGoForward)
                .accessibilityLabel("Forward")
            Spacer()
            AppSectionMenu()
                .frame(width: 44, height: 44)
            Button { showingTabOverview = true } label: {
                tabBarButtonLabel {
                    ZStack {
                        Image(systemName: "square.on.square")
                        Text("\(app.contentTabs.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .offset(y: -1)
                    }
                }
            }
            .accessibilityLabel("Show \(app.contentTabs.count) tabs")
        }
        .font(.headline)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func tabBarButtonLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

@MainActor
struct MobileTabOverview: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columnCount = max(2, Int(geometry.size.width / 190))
                let cardWidth = (geometry.size.width - CGFloat(32) - CGFloat(columnCount - 1) * CGFloat(16))
                    / CGFloat(columnCount)
                let tabCount = app.contentTabs.count
                let rowCount = (tabCount + columnCount - 1) / columnCount
                ScrollView {
                    VStack(spacing: 18) {
                        ForEach(0..<rowCount, id: \.self) { row in
                            HStack(spacing: 16) {
                                ForEach(0..<columnCount, id: \.self) { column in
                                    let index = row * columnCount + column
                                    if app.contentTabs.indices.contains(index) {
                                        let tab = app.contentTabs[index]
                                        TabOverviewCard(
                                            width: cardWidth,
                                            title: tab.title,
                                            systemImage: tab.previewSystemImage,
                                            thumbnailURL: tab.previewThumbnailURL,
                                            isActive: app.activeTabID == tab.id,
                                            onSelect: { select(tab.id) },
                                            onClose: { app.closeTab(tab.id) }
                                        )
                                    } else {
                                        Color.clear.frame(width: cardWidth)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            #if os(tvOS)
            .background(.thickMaterial)
            #else
            .background(Color.secondary.opacity(0.08))
            #endif
            .navigationTitle("Tabs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        app.openNewTab()
                        isPresented = false
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New tab")
                }
                #endif
            }
        }
    }

    private func select(_ id: BrowserTab.ID) {
        app.activeTabID = id
        isPresented = false
    }
}

@MainActor
private struct TabOverviewCard: View {
    let width: CGFloat
    let title: String
    let systemImage: String
    let thumbnailURL: URL?
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(title)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)

            Button(action: onSelect) {
                Group {
                    if let thumbnailURL {
                        RemoteImage(url: thumbnailURL, contentMode: .fill)
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.08)
                            Image(systemName: systemImage)
                                .font(.system(size: 42))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .buttonStyle(.plain)
            // Constrain the button horizontally, but leave its height to the
            // finite card layout. An infinite height inside this ScrollView
            // creates an unbounded proposal and can blank the render surface.
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityLabel("Open \(title)")
        }
        // Establish finite layout bounds before clipping. A caller-applied
        // frame changes only the card's reported size; an aspect-fill image
        // can otherwise keep oversized internal drawing bounds.
        .frame(width: width, height: width / 0.72)
        // SwiftUI permits descendants to render outside a parent's layout
        // bounds. Establish a hard card boundary before applying the rounded
        // mask and the intentionally out-of-bounds shadow.
        .clipped()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isActive ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isActive ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private extension BrowserTab {
    var previewThumbnailURL: URL? {
        guard case .item(let item) = current else { return nil }
        return item.thumbnailURL
    }

    var previewSystemImage: String {
        switch current {
        case .home: return "house"
        case .subscriptions: return "rectangle.stack.person.crop"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .sources: return "puzzlepiece.extension"
        case .item(let item):
            switch item.kind {
            case .playlist: return "list.bullet.rectangle"
            case .channel: return "person.crop.circle"
            case .post, .article: return "doc.text"
            default: return "play.rectangle"
            }
        case .channel: return "person.crop.circle"
        case .playlist: return "list.bullet.rectangle"
        case .plugin: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        case .content: return "play.rectangle"
        case nil: return "house"
        }
    }
}
