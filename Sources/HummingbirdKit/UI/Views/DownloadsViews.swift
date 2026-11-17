import Foundation
import Observation
import SwiftOpenUI

/// The downloads list for one window: every VOD download and live recording
/// in the shared media cache (`MediaDownloads`), refreshed while the window
/// exists. Actions are never optimistic: a row shows a spinner and its
/// controls are disabled until the action has taken effect.
@MainActor
@Observable
final class DownloadsModel {
    private(set) var items: [DownloadSnapshot] = []
    /// Rows whose action is still being carried out.
    private(set) var pending: Set<String> = []
    private(set) var isClearing = false
    /// Why the last Remove did not happen (the video is playing).
    private(set) var notice: String?

    @ObservationIgnored private let downloads: MediaDownloads
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(downloads: MediaDownloads) {
        self.downloads = downloads
    }

    /// Follows the list until `stop`: every second while something downloads,
    /// every five seconds otherwise.
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let active = self.items.contains { $0.state == .downloading || $0.state == .waitingForNetwork }
                try? await Task.sleep(for: .seconds(active ? 1 : 5))
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        let latest = await downloads.snapshot()
        if latest != items { items = latest }
    }

    /// The button shows while anything is downloading or recently finished.
    var isVisible: Bool { !items.isEmpty }

    /// Overall progress for the button's ring.
    var overallFraction: Double {
        let active = items.filter { $0.state != .complete && $0.state != .stopped }
        guard !active.isEmpty else { return 1 }
        return active.map(\.fraction).reduce(0, +) / Double(active.count)
    }

    var isDownloading: Bool { items.contains { $0.state == .downloading || $0.state == .waitingForNetwork } }

    func setPaused(_ paused: Bool, _ item: DownloadSnapshot) async {
        await perform(item.id) { await self.downloads.setPaused(paused, download: item.id) }
    }

    func stopDownload(_ item: DownloadSnapshot) async {
        await perform(item.id) { await self.downloads.stop(download: item.id) }
    }

    func remove(_ item: DownloadSnapshot) async {
        await perform(item.id) {
            if !(await self.downloads.remove(download: item.id)) {
                self.notice = "\"\(item.info.title)\" is playing. Close it to remove its download."
            }
        }
    }

    func clearFinished() async {
        isClearing = true
        defer { isClearing = false }
        await downloads.clearFinished()
        await refresh()
    }

    private func perform(_ id: String, _ action: @escaping @MainActor () async -> Void) async {
        pending.insert(id)
        notice = nil
        await action()
        await refresh()
        pending.remove(id)
    }
}

/// The window's Downloads button: shown while anything is downloading or
/// recently finished, with a ring for overall progress; opens the list.
/// Placed as a window item (`browserWindowItem`), never in a page toolbar or
/// the tab overview.
@MainActor
struct DownloadsButton: View {
    let model: DownloadsModel
    @State private var showingList = false

    var body: some View {
        if model.isVisible {
            Button { showingList.toggle() } label: {
                ZStack {
                    if model.isDownloading {
                        ProgressRing(fraction: model.overallFraction, lineWidth: 2).frame(width: 22, height: 22)
                    }
                    Image(systemName: "arrow.down")
                        .font(.system(size: model.isDownloading ? 10 : 14, weight: .semibold))
                }
                .frame(width: 24, height: 24)
            }
            .accessibilityLabel(model.isDownloading
                ? "Downloads, \(Int(model.overallFraction * 100)) percent" : "Downloads")
            .popover(isPresented: $showingList) {
                DownloadsList(model: model) { showingList = false }
            }
        }
    }
}

@MainActor
private struct DownloadsList: View {
    let model: DownloadsModel
    let dismiss: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if model.isClearing {
                    ProgressView()
                } else {
                    Button("Clear") { Task { await model.clearFinished() } }
                        .disabled(!model.items.contains { $0.state == .complete || $0.state == .stopped })
                }
            }
            .padding(12)
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items) { item in
                        DownloadRow(item: item, isPending: model.pending.contains(item.id), model: model) {
                            app.openInNewTab(.content(item.info.contentURL), title: item.info.title)
                            dismiss()
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
    }
}

@MainActor
private struct DownloadRow: View {
    let item: DownloadSnapshot
    let isPending: Bool
    let model: DownloadsModel
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(url: item.info.thumbnail, contentMode: .fill)
                .frame(width: 48, height: 27)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.info.title).font(.subheadline).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if item.state == .downloading || item.state == .waitingForNetwork || item.state == .paused {
                    ProgressView(value: item.fraction)
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var actions: some View {
        if isPending {
            // The action is being carried out; its result shows when it is done.
            ProgressView()
        } else {
            HStack(spacing: 6) {
                switch item.state {
                case .downloading, .waitingForNetwork:
                    Button { Task { await model.setPaused(true, item) } } label: {
                        Image(systemName: "pause.circle").accessibilityLabel("Pause")
                    }
                    Button { Task { await model.stopDownload(item) } } label: {
                        Image(systemName: "xmark.circle").accessibilityLabel("Stop")
                    }
                    .disabled(item.isPlaying)
                case .paused:
                    Button { Task { await model.setPaused(false, item) } } label: {
                        Image(systemName: "play.circle").accessibilityLabel("Resume")
                    }
                case .complete, .stopped:
                    Button { Task { await model.remove(item) } } label: {
                        Image(systemName: "trash").accessibilityLabel("Remove download")
                    }
                    .disabled(item.isPlaying)
                }
                Button(action: open) {
                    Image(systemName: "magnifyingglass.circle").accessibilityLabel("Show video")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var status: String {
        let size = Fmt.bytes(item.bytes)
        switch item.state {
        case .downloading:
            let speed = item.bytesPerSecond > 0 ? " · \(Fmt.bytes(Int64(item.bytesPerSecond)))/s" : ""
            return (item.info.isLive ? "Recording live" : "\(Int(item.fraction * 100))%") + (item.bytes > 0 ? " · \(size)" : "") + speed
        case .waitingForNetwork: return "Waiting for the network"
        case .paused: return "Paused · \(Int(item.fraction * 100))%"
        case .complete: return item.bytes > 0 ? "Downloaded · \(size)" : "Downloaded"
        case .stopped: return "Stopped · \(Int(item.fraction * 100))%"
        }
    }
}

/// Media downloads that continue while the app is suspended (iOS, iPadOS,
/// tvOS, visionOS), through SwiftOpenUI's `BackgroundTransferSession`; an
/// ordinary session where processes keep running (macOS, GTK).
struct BackgroundTransport: MediaTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await BackgroundTransferSession.shared.data(for: request)
    }
}
