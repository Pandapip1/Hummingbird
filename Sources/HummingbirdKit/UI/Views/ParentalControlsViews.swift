import Foundation
import SwiftOpenUI

/// Why a source is locked, and, when the system's parental controls apply,
/// a button that asks a parent through the system (Screen Time on Apple
/// platforms). Hummingbird has no passcode of its own.
@MainActor
struct PolicyDenialSection: View {
    let refusal: PolicyRefusal
    @Environment(AppModel.self) private var app
    @State private var asking = false
    @State private var outcome: String?

    var body: some View {
        Section {
            Label {
                Text(refusal.denial.errorDescription ?? "Not available")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.fill")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Locked. \(refusal.denial.errorDescription ?? "")")
            if refusal.denial.parentCanApprove {
                if asking {
                    HStack(spacing: 8) {
                        Text("Asking a parent…")
                        ProgressView()
                    }
                    .accessibilityElement(children: .combine)
                } else if let outcome {
                    Text(outcome).font(.footnote).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Ask a Parent", action: ask)
                }
            }
        }
    }

    private func ask() {
        guard !asking else { return }
        asking = true
        Task {
            defer { asking = false }
            let request = await app.plugins.policy.askParent(
                pluginID: refusal.pluginID, name: refusal.name, sourceURL: refusal.sourceURL, denial: refusal.denial
            )
            switch request {
            case .sent:
                outcome = "Request sent. \(refusal.name) installs when a parent approves it."
            case .unavailable:
                outcome = "This system can’t send the request. A parent can change parental controls in system settings."
            }
        }
    }
}

/// Settings ▸ Age & Parental Controls. Shows what the system reports, the
/// profile's age, and parents' approvals. Parental controls themselves are
/// the system's (Screen Time, malcontent); nothing here needs a passcode,
/// because everything it offers only restricts.
@MainActor
struct ParentalControlsView: View {
    @Environment(AppModel.self) private var app
    @State private var status: SystemParentalControls.Status?
    @State private var choosingLowerAge = false
    @State private var lowering = false

    private var policy: SourceAccessPolicy { app.plugins.policy }

    var body: some View {
        Form {
            Section {
                switch status {
                case nil:
                    ProgressView("Checking parental controls…")
                case .notSupervised?:
                    Text("No parental controls are set for this account. Parents set them in the system: Screen Time on Apple devices, Parental Controls on Linux.")
                        .fixedSize(horizontal: false, vertical: true)
                case .supervised?:
                    Text("Parental controls are on for this account. Sources a parent hasn’t approved stay locked, and age-restricted modes stay on.")
                        .fixedSize(horizontal: false, vertical: true)
                case .unavailable?:
                    Text("This system doesn’t report parental controls.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Parental controls")
            }

            Section {
                let minimum = policy.profileAge.record?.minimumAge(on: Date())
                LabeledContent("Age on this profile", value: minimum.map { "\($0) or older" } ?? "Not known")
                if let minimum, minimum > 0 {
                    if lowering {
                        HStack(spacing: 8) {
                            Text("Lowering…")
                            ProgressView()
                        }
                    } else {
                        Button("Lower the Age…") { choosingLowerAge = true }
                    }
                }
            } header: {
                Text("Age")
            } footer: {
                Text("The age comes from the system’s age range, on any device of this profile, and only rises on its own. If it’s too high, lower it here: that only restricts, so anyone can.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !policy.approvals.approved.isEmpty {
                Section("Approved by a parent") {
                    ForEach(policy.approvals.approved.keys.sorted(), id: \.self) { id in
                        HStack {
                            Text(app.plugins.plugin(id)?.config.name ?? id)
                            Spacer()
                            Button("Withdraw", role: .destructive) {
                                Task { await policy.approvals.withdraw(id) }
                            }
                        }
                    }
                }
            }
            if !policy.approvals.pending.isEmpty {
                Section("Waiting for a parent") {
                    ForEach(policy.approvals.pending) { request in
                        Text(request.name)
                    }
                }
            }
        }
        .navigationTitle("Age & Parental Controls")
        .task {
            _ = await policy.profileAge.current()
            _ = await policy.approvals.current()
            status = await policy.supervisionSource.status()
        }
        .confirmationDialog("Lower this profile’s age?", isPresented: $choosingLowerAge, titleVisibility: .visible) {
            ForEach([0, 13, 16].filter { $0 < (policy.profileAge.record?.minimumAge(on: Date()) ?? 0) }, id: \.self) { age in
                Button(age == 0 ? "Under 13" : "\(age) or older") { lower(to: age) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sources rated above the new age lock on every device of this profile, and age-restricted modes turn on. The system’s age range can raise it again.")
        }
    }

    private func lower(to age: Int) {
        lowering = true
        Task {
            defer { lowering = false }
            await policy.profileAge.lower(toMinimumAge: age)
        }
    }
}

/// Under the system's parental controls, a rated setting held at its safe
/// value offers Ask a Parent; approved, the source restarts with it allowed.
@MainActor
struct LockedSettingAskParent: View {
    let pluginID: String
    let setting: PluginSetting
    @Environment(AppModel.self) private var app
    @State private var denial: PolicyDenial?
    @State private var asking = false
    @State private var outcome: String?

    var body: some View {
        Group {
            if let denial, denial.parentCanApprove {
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
        .task(id: setting.key) {
            guard let plugin = app.plugins.plugin(pluginID),
                  let raising = app.plugins.policy.classification(for: plugin.config).settingRatings
                    .first(where: { $0.setting == setting.key })?.values.first else { return }
            denial = await app.plugins.policy.approveSettingChange(plugin.config, setting: setting.key, value: raising)
        }
    }

    private func ask() {
        guard let denial, let plugin = app.plugins.plugin(pluginID) else { return }
        asking = true
        Task {
            defer { asking = false }
            switch await app.plugins.policy.askParent(pluginID: pluginID, name: plugin.config.name,
                                                     setting: setting.key, settingName: setting.name, denial: denial) {
            case .sent: outcome = "Request sent. The setting unlocks when a parent approves it."
            case .unavailable: outcome = "This system can’t send the request."
            }
        }
    }
}
