import ATAppSync
import Foundation
import PlatformSupport
import SwiftOpenUI

/// Turns new-video notifications for a subscribed channel on or off. The
/// setting syncs; each device then notifies on its own. Turning it on asks
/// the system for permission first: meanwhile the control is disabled with
/// a spinner, and it shows the real result (on, or why not).
@MainActor
struct NewVideoNotificationButton: View {
    let channelURL: String
    @Environment(AppModel.self) private var app
    @State private var asking = false
    @State private var refusal: String?

    var body: some View {
        let on = app.library.notifiesOnNewVideos(channelURL)
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                Task { await toggle(on: !on) }
            } label: {
                if asking {
                    ProgressView()
                } else {
                    Image(systemName: on ? "bell.fill" : "bell")
                }
            }
            .buttonStyle(.bordered)
            .disabled(asking)
            .accessibilityLabel(on ? "Stop notifying about new videos" : "Notify about new videos")
            if let refusal {
                Text(refusal).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }

    private func toggle(on: Bool) async {
        refusal = nil
        guard on else {
            app.library.setNotifyOnNewVideos(false, channelURL: channelURL)
            return
        }
        asking = true
        defer { asking = false }
        let center = LocalNotifications.center
        var authorization = await center.authorization()
        if authorization == .notDetermined { authorization = await center.requestAuthorization() }
        switch authorization {
        case .authorized:
            app.library.setNotifyOnNewVideos(true, channelURL: channelURL)
        case .denied:
            refusal = "Notifications are turned off for Hummingbird in the system’s settings."
        case .unsupported:
            refusal = "This device doesn’t show notifications."
        case .notDetermined:
            refusal = "Notifications weren’t allowed."
        }
    }
}

/// Settings › Storage: the synced data cache's size, its budget, and the one
/// action that wipes it (on this device only).
@MainActor
struct SyncedCacheSection: View {
    let cache: CacheJournal
    let defaults: UserDefaults
    @State private var usage: CacheJournal.Usage?
    @State private var budget: Int
    @State private var working = false
    @State private var confirmingClear = false
    @State private var failure: String?

    init(cache: CacheJournal, defaults: UserDefaults) {
        self.cache = cache
        self.defaults = defaults
        _budget = State(initialValue: defaults.object(forKey: SyncedCache.budgetKey) as? Int ?? SyncedCache.defaultBudgetMegabytes)
    }

    var body: some View {
        Section(footer: Text("Channel and video details your devices fetched, shared between your trusted devices so one device’s refresh saves the others a trip. Encrypted, and only on your devices. Clearing it removes it from this device only.")) {
            Picker("Synced cache", selection: $budget) {
                ForEach(SyncedCache.budgetChoices, id: \.self) { megabytes in
                    Text(megabytes >= 1_024 ? "\(megabytes / 1_024) GB" : "\(megabytes) MB").tag(megabytes)
                }
            }
            HStack {
                Text("In use")
                Spacer()
                if working || usage == nil {
                    ProgressView()
                } else if let usage {
                    Text(Fmt.bytes(Int64(usage.bytes))).foregroundStyle(.secondary)
                }
            }
            Button("Clear synced cache", role: .destructive) { confirmingClear = true }
                .disabled(working || usage == nil)
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task(id: budget) {
            // A smaller budget evicts what no longer fits before the usage is shown.
            working = true
            defaults.set(budget, forKey: SyncedCache.budgetKey)
            let cache = cache
            let budget = budget
            usage = await Task.detached {
                cache.setBudget(budget * 1_024 * 1_024)
                cache.persist()
                return cache.usage
            }.value
            working = false
        }
        .confirmationDialog("Clear the synced cache on this device?", isPresented: $confirmingClear) {
            Button("Clear synced cache", role: .destructive) { Task { await clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Channels and videos load from your other devices or their sources again. Your history, library and settings aren’t affected, and your other devices keep their copies.")
        }
    }

    private func clear() async {
        working = true
        failure = nil
        let cache = cache
        do {
            usage = try await Task.detached {
                try cache.clear()
                return cache.usage
            }.value
        } catch {
            failure = "The synced cache couldn’t be cleared: \(error.localizedDescription)"
            usage = cache.usage
        }
        working = false
    }
}
