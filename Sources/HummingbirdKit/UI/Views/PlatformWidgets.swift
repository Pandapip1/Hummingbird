import Foundation
import SwiftOpenUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

@MainActor
struct ExternalURLLink<Label: View>: View {
    let destination: URL
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        Link(destination: destination, label: label)
        #else
        Button { SystemServices.openURL(destination) } label: { label() }
        #endif
    }
}

@MainActor
struct LazyContentStack<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        LazyVStack(alignment: alignment, spacing: spacing ?? 8, content: content)
        #else
        VStack(alignment: alignment, spacing: spacing ?? 8, content: content)
        #endif
    }
}

extension View {
    func hiddenListRowSeparator() -> some View {
        #if os(tvOS)
        self
        #else
        listRowSeparator(.hidden)
        #endif
    }

    /// Automatic pagination is valid only for backends with lazy row realization.
    func loadsNextPageWhenLast(_ isLast: Bool, _ load: @escaping () async -> Void) -> some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        onAppear { if isLast { Task { await load() } } }
        #else
        self
        #endif
    }
}

@MainActor
struct LoadMoreButton: View {
    let feed: FeedModel

    var body: some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        EmptyView()
        #else
        if feed.hasMore && !feed.isLoading {
            Button("Load more") { Task { await feed.loadMore() } }
                .frame(maxWidth: .infinity)
        }
        #endif
    }
}

// Platform-specific UI belongs in this file. Feature screens consume widgets
// named for the behavior they provide instead of knowing which OS provides it.

extension View {
    @ViewBuilder
    func detailNavigationStyle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func editableCollectionToolbar(id: String) -> some View {
        #if os(iOS)
        browserTabToolbarItem(id: id, placement: .trailing) { EditButton() }
        #else
        self
        #endif
    }

    @ViewBuilder
    func destructiveRowAction(_ title: String, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        swipeActions { Button(title, role: .destructive, action: action) }
        #endif
    }

    @ViewBuilder
    func searchSubmission(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onSubmit(action)
        #else
        onSubmit(of: .search, action)
        #endif
    }

    @ViewBuilder
    func urlEntryStyle() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).keyboardType(.URL)
        #else
        self
        #endif
    }

    @ViewBuilder
    func settingsTextEntryStyle() -> some View {
        #if os(tvOS)
        self
        #else
        textFieldStyle(.roundedBorder)
        #endif
    }

    @ViewBuilder
    func focusableReadOnlyValue() -> some View {
        #if os(tvOS)
        focusable()
        #else
        self
        #endif
    }

    @ViewBuilder
    func immersiveVideoDetailStyle() -> some View {
        #if os(iOS)
        ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

struct FocusableReadOnlyModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.focusableReadOnlyValue()
    }
}

private struct SearchEntryModifier: ViewModifier {
    @Binding var query: String
    let hidden: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if hidden {
            content
        } else {
            #if os(tvOS)
            content.safeAreaInset(edge: .top, spacing: 0) {
                TextField("Search or paste a link", text: $query)
                    .padding(.horizontal, 80)
                    .padding(.bottom, 12)
            }
            #elseif os(iOS)
            content.searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search or paste a link"
            )
            #elseif os(macOS)
            content.browserTabToolbarItem(id: "search.field", placement: .principal) {
                TextField("Search or paste a link", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260, idealWidth: 420, maxWidth: 560)
            }
            #else
            content.searchable(text: $query, prompt: "Search or paste a link")
            #endif
        }
    }
}

extension View {
    func searchEntry(query: Binding<String>, hidden: Bool) -> some View {
        modifier(SearchEntryModifier(query: query, hidden: hidden))
    }
}

@MainActor
struct FocusBrowserToolbar: ToolbarContent {
    let browserToolbar: BrowserToolbarContext?

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if os(tvOS)
        if let browserToolbar {
            BrowserTopToolbar(tab: browserToolbar.tab, showTabOverview: browserToolbar.showTabOverview)
        }
        #else
        ToolbarItem { EmptyView() }
        #endif
    }
}

@MainActor
struct FocusNavigationLink<Destination: View, Label: View>: ToolbarContent {
    let isActive: Bool
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if os(tvOS)
        if isActive {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: destination, label: label)
            }
        }
        #else
        ToolbarItem { EmptyView() }
        #endif
    }
}

@MainActor
struct FocusPrimaryAction<Label: View>: ToolbarContent {
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if os(tvOS)
        if isActive {
            ToolbarItem(placement: .primaryAction) {
                Button(action: action, label: label)
            }
        }
        #else
        ToolbarItem { EmptyView() }
        #endif
    }
}

@MainActor
struct RemoteFriendlyBoundedSelection: View {
    let title: String
    @Binding var value: Int
    let values: [Int]
    let zeroLabel: String
    let step: Int

    var body: some View {
        #if os(tvOS)
        Picker(title, selection: $value) {
            Text(zeroLabel).tag(0)
            ForEach(values.filter { $0 != 0 }, id: \.self) { Text(String($0)).tag($0) }
        }
        #else
        Stepper("\(title): \(value == 0 ? zeroLabel.lowercased() : String(value))",
                value: $value, in: (values.min() ?? 0)...(values.max() ?? 0), step: step)
        #endif
    }
}

@MainActor
struct FocusableReadOnlyValue: View {
    let text: String
    var monospaced = false
    var accessibilityIdentifier: String?

    var body: some View {
        Text(text)
            .font(monospaced ? .footnote.monospaced() : .body)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
            .focusableReadOnlyValue()
    }
}

@MainActor
struct ShareContentAction<Label: View>: View {
    let item: URL?
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        if let item { ShareLink(item: item, label: label) }
        #endif
    }
}

@MainActor
struct SettingsDetailContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS) && !BACKEND_GTK
        ScrollView { content() }.defaultScrollAnchor(.top)
        #else
        content()
        #endif
    }
}

enum QRCodeScanning {
    static let isAvailable: Bool = {
        #if canImport(AVFoundation)
        AVCaptureDevice.default(for: .video) != nil
        #else
        false
        #endif
    }()
}

@MainActor
struct QRCodeScanner: View {
    let instruction: String
    let onCode: (String) -> Void

    var body: some View {
        #if (os(iOS) || os(macOS)) && !BACKEND_GTK
        QRScannerView(onCode: onCode)
            #if os(iOS)
            .ignoresSafeArea()
            #endif
            .overlay(alignment: .bottom) {
                Text(instruction).padding(10).background(.thinMaterial, in: Capsule()).padding()
            }
        #else
        Text("QR scanning is not available on this platform. Paste the URL instead.")
        #endif
    }
}

@MainActor
struct DocumentTransferControls: View {
    let title: String
    let exportURL: URL?
    let exportLabel: String
    let importLabel: String
    let status: String?
    let requestImport: () -> Void

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        Section(title) {
            if let exportURL {
                ShareLink(item: exportURL) { Label(exportLabel, systemImage: "square.and.arrow.up") }
            } else {
                Label("Preparing export…", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            Button(action: requestImport) {
                Label(importLabel, systemImage: "square.and.arrow.down")
            }
            if let status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        }
        #endif
    }
}

private struct JSONDocumentImporter: ViewModifier {
    @Binding var isPresented: Bool
    let importBackup: (URL) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importBackup(url)
        }
        #endif
    }
}

extension View {
    func jsonDocumentImporter(isPresented: Binding<Bool>, onImport: @escaping (URL) -> Void) -> some View {
        modifier(JSONDocumentImporter(isPresented: isPresented, importBackup: onImport))
    }

    @ViewBuilder
    func preparesDocumentExport(id: String, _ prepare: @escaping @Sendable () async -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        task(id: id, prepare)
        #endif
    }
}
