import Foundation
import SwiftOpenUI

/// Sources ▸ Discover: the reviewed sources (`CuratedSourceDatabase`),
/// each with its rating. What this user may add is decided by the
/// source-access policy, asked once for the list: sources rated above a
/// known age are left out, ones that need a shared age or a parent's
/// approval are shown locked with the reason.
@MainActor
struct DiscoverSourcesView: View {
    @Environment(AppModel.self) private var app
    @State private var visibility: [String: CatalogVisibility]?
    @State private var adding: CuratedSourceEntry?

    private var entries: [CuratedSourceEntry] {
        app.plugins.policy.classifier.reviewedEntries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if let visibility {
                let shown = entries.filter { visibility[$0.pluginID] != .hidden }
                ForEach(SourceCategory.allCases, id: \.self) { category in
                    let inCategory = shown.filter { $0.category == category }
                    if !inCategory.isEmpty {
                        Section(Self.title(for: category)) {
                            ForEach(inCategory) { entry in
                                row(entry, visibility: visibility[entry.pluginID] ?? .available)
                            }
                        }
                    }
                }
                if shown.count < entries.count {
                    Section {
                        Text("Some sources aren’t shown because they’re rated above your age.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Checking which sources you can add…")
            }
        }
        .navigationTitle("Discover Sources")
        .task {
            visibility = await app.plugins.policy.visibility(ofReviewed: entries)
        }
        .sheet(item: $adding) { entry in
            AddSourceSheet(initialURL: entry.configURL)
        }
    }

    @ViewBuilder
    private func row(_ entry: CuratedSourceEntry, visibility: CatalogVisibility) -> some View {
        let rating = entry.classification.minimumAge
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.headline)
                Text(rating == 0 ? "All ages" : "\(rating)+")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(rating == 0 ? "Rated for all ages" : "Rated \(rating) and over")
                Spacer()
                if app.plugins.plugin(entry.pluginID) != nil {
                    Text("Added").font(.caption).foregroundStyle(.secondary)
                } else if visibility == .available {
                    Button("Add") { adding = entry }
                        .accessibilityLabel("Add \(entry.name)")
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        .accessibilityLabel("Locked")
                }
            }
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .locked(let denial) = visibility, app.plugins.plugin(entry.pluginID) == nil {
                LockedReviewedSource(refusal: PolicyRefusal(
                    denial: denial, pluginID: entry.pluginID, name: entry.name, sourceURL: entry.configURL
                ))
            }
        }
    }

    static func title(for category: SourceCategory) -> String {
        switch category {
        case .generalVideo: return "Video platforms"
        case .music: return "Music"
        case .podcasts: return "Podcasts"
        case .news: return "News"
        case .education: return "Learning"
        case .adult: return "Adult"
        case .unknown: return "Other"
        }
    }
}

/// The reason a reviewed source is locked, and Ask a Parent when the
/// system's parental controls can approve it.
@MainActor
private struct LockedReviewedSource: View {
    let refusal: PolicyRefusal
    @Environment(AppModel.self) private var app
    @State private var asking = false
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(refusal.denial.errorDescription ?? "Not available.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if refusal.denial.parentCanApprove {
                if asking {
                    HStack(spacing: 8) {
                        Text("Asking a parent…").font(.caption)
                        ProgressView()
                    }
                } else if let outcome {
                    Text(outcome).font(.caption).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Ask a Parent", action: ask).font(.caption)
                }
            }
        }
    }

    private func ask() {
        asking = true
        Task {
            defer { asking = false }
            switch await app.plugins.policy.askParent(pluginID: refusal.pluginID, name: refusal.name,
                                                     sourceURL: refusal.sourceURL, denial: refusal.denial) {
            case .sent: outcome = "Request sent. \(refusal.name) is added when a parent approves it."
            case .unavailable: outcome = "This system can’t send the request. A parent can change parental controls in system settings."
            }
        }
    }
}
