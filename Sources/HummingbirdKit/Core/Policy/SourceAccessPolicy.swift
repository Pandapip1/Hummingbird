import Foundation
import SwiftOpenUI

// MARK: approvals

/// Permission to store one previewed plugin. Only `PolicyRules` can make one,
/// and `InstallPreview` cannot exist without it, so every install path
/// (Add Source URL, QR, grayjay:// links, the discovery page, sync, updates)
/// has to pass the policy to compile.
struct InstallApproval: Sendable, Equatable {
    let pluginID: String
    fileprivate init(pluginID: String) { self.pluginID = pluginID }
}

/// Permission to start one plugin's JavaScript runtime, with the settings the
/// policy forces on it (restricted modes). `PluginRuntime.init` requires it.
struct LoadApproval: Sendable, Equatable {
    let pluginID: String
    /// Setting values that replace the user's for this runtime only. The
    /// user's stored settings are left as they are.
    let forcedSettings: [String: String]
    fileprivate init(pluginID: String, forcedSettings: [String: String]) {
        self.pluginID = pluginID
        self.forcedSettings = forcedSettings
    }
}

// MARK: inputs

/// What one decision knows about the user's age.
enum AgeEvidence: Sendable, Equatable {
    /// Bounds inclusive; `upper` nil means open-ended.
    case range(lower: Int, upper: Int?)
    /// The user (or whoever manages their account) chose not to share. It
    /// carries no information: a profile bound replaces it when there is one.
    case declined
    /// The platform has no age source (older OS, no birth date in the
    /// systemd user record, no Windows family settings). Adult by product
    /// decision, unless the system reports parental controls.
    case unknown

    init(_ answer: AgeAssurance.Answer) {
        switch answer {
        case .range(let lower, let upper): self = .range(lower: lower ?? 0, upper: upper)
        case .declined: self = .declined
        case .unavailable: self = .unknown
        }
    }

    /// true or false when the evidence settles it, nil when it doesn't
    /// (declined, or a range that straddles `age`).
    func isAtLeast(_ age: Int) -> Bool? {
        switch self {
        case .unknown: return true
        case .declined: return nil
        case .range(let lower, let upper):
            if lower >= age { return true }
            if let upper, upper < age { return false }
            return nil
        }
    }
}

/// The system's parental controls (Screen Time, malcontent, Family Safety)
/// as a decision sees them. Hummingbird has no parental passcode of its own.
enum Supervision: Sendable, Equatable {
    /// No parental controls reported, or the system cannot say.
    case none
    case supervised(allowsInstallingApps: Bool, contentAgeLimit: Int?)

    init(_ status: SystemParentalControls.Status) {
        switch status {
        case .notSupervised, .unavailable: self = .none
        case .supervised(let installs, let limit):
            self = .supervised(allowsInstallingApps: installs, contentAgeLimit: limit)
        }
    }

    var isSupervised: Bool { self != .none }
}

// MARK: decisions

/// Why the policy said no, in words the UI shows as-is.
enum PolicyDenial: LocalizedError, Equatable, Sendable, Codable {
    /// The source is rated above the user's age.
    case tooYoung(minimumAge: Int)
    /// The source needs an age the user hasn't shared.
    case ageNotConfirmed(minimumAge: Int)
    /// The system's parental controls apply; a parent can approve it
    /// through the system ("Ask a Parent").
    case needsParentApproval(minimumAge: Int, unlisted: Bool)

    var errorDescription: String? {
        switch self {
        case .tooYoung(let age):
            return "This source is for people \(age) or older."
        case .ageNotConfirmed(let age):
            return "This source is for people \(age) or older, and your age wasn’t shared. Share your age range in system settings to continue."
        case .needsParentApproval(let age, let unlisted):
            let what = unlisted ? "This source isn’t on Hummingbird’s reviewed list" : "This source is rated \(age)+"
            return "\(what), and parental controls are on. A parent needs to approve it."
        }
    }

    /// Whether the system's parent-approval flow can turn this into a yes.
    var parentCanApprove: Bool {
        if case .needsParentApproval = self { return true }
        return false
    }
}

/// How a curated catalog entry (task 59's discovery page) is shown.
enum CatalogVisibility: Equatable, Sendable {
    case available
    /// Shown, but installing needs a shared age or a parent's approval.
    case locked(PolicyDenial)
    /// Not shown: rated above the user's known age.
    case hidden
}

/// The policy's rules as pure functions of their inputs, so every case can be
/// tested and none depends on remembered state. `SourceAccessPolicy` gathers
/// the inputs and calls these.
enum PolicyRules {
    /// Ages the decisions care about. Declared Age Range accepts three.
    static let ageGates = [13, 16, 18]
    static let adultAge = 18

    /// `parentApproved`: a parent approved this source through the system.
    static func install(
        _ source: SourceClassification, age: AgeEvidence, supervision: Supervision, parentApproved: Bool
    ) -> Result<InstallApproval, PolicyDenial> {
        if let denial = denial(source, age: age, supervision: supervision, parentApproved: parentApproved,
                               phase: .install) {
            return .failure(denial)
        }
        return .success(InstallApproval(pluginID: source.pluginID))
    }

    /// `approvedSettings`: rated settings a parent approved for this source.
    static func load(
        _ source: SourceClassification, age: AgeEvidence, supervision: Supervision, parentApproved: Bool,
        approvedSettings: Set<String> = []
    ) -> Result<LoadApproval, PolicyDenial> {
        if let denial = denial(source, age: age, supervision: supervision, parentApproved: parentApproved,
                               phase: .load) {
            return .failure(denial)
        }
        // A setting that would raise the rating above what this user may
        // have is held at its safe value (the source's restricted mode).
        var forced: [String: String] = [:]
        for condition in source.settingRatings where !approvedSettings.contains(condition.setting) {
            if settingDenial(condition, age: age, supervision: supervision) != nil {
                forced[condition.setting] = condition.safeValue
            }
        }
        return .success(LoadApproval(pluginID: source.pluginID, forcedSettings: forced))
    }

    /// Whether changing `setting` to `value` is allowed, gated like an
    /// install of the source at the rating that value gives it.
    static func settingChange(
        _ source: SourceClassification, setting: String, value: String, age: AgeEvidence,
        supervision: Supervision, approvedSettings: Set<String> = []
    ) -> PolicyDenial? {
        guard !approvedSettings.contains(setting),
              let condition = source.settingRatings.first(where: { $0.setting == setting && $0.values.contains(value) })
        else { return nil }
        return settingDenial(condition, age: age, supervision: supervision)
    }

    /// The refusal a rated setting gets: the same as installing a reviewed
    /// source with that setting's rating.
    private static func settingDenial(_ condition: SettingRating, age: AgeEvidence,
                                      supervision: Supervision) -> PolicyDenial? {
        let rated = SourceClassification(pluginID: "", isCurated: true, category: .unknown,
                                         explicitMinimumAge: condition.minimumAge)
        return denial(rated, age: age, supervision: supervision, parentApproved: false, phase: .install)
    }

    static func visibility(
        _ source: SourceClassification, age: AgeEvidence, supervision: Supervision, parentApproved: Bool
    ) -> CatalogVisibility {
        guard let denial = denial(source, age: age, supervision: supervision, parentApproved: parentApproved,
                                  phase: .install) else { return .available }
        switch denial {
        case .tooYoung: return .hidden
        case .ageNotConfirmed, .needsParentApproval: return .locked(denial)
        }
    }

    /// The age a decision uses: this device's report combined with the
    /// minimum age the profile's birthday bound proves today. With a bound,
    /// "declined" and "unavailable" give way to it (at least that old, no
    /// upper limit); without one they keep their own meaning.
    static func effectiveAge(device: AgeEvidence, profileMinimumAge: Int?) -> AgeEvidence {
        guard let minimum = profileMinimumAge else { return device }
        switch device {
        case .range(let lower, let upper):
            let combined = max(lower, minimum)
            return .range(lower: combined, upper: upper.flatMap { $0 >= combined ? $0 : nil })
        case .declined, .unknown:
            return .range(lower: minimum, upper: nil)
        }
    }

    private enum Phase { case install, load }

    private static func denial(
        _ source: SourceClassification, age: AgeEvidence, supervision: Supervision,
        parentApproved: Bool, phase: Phase
    ) -> PolicyDenial? {
        // A parent's approval through the system settles it.
        if parentApproved { return nil }
        // Unlisted sources are rated as adult content.
        let minimumAge = source.isCurated ? source.minimumAge : max(source.minimumAge, adultAge)

        var refusal: PolicyDenial?
        if minimumAge > 0 {
            // No platform age counts as adult only without parental controls.
            let atLeast = age == .unknown && supervision.isSupervised ? nil : age.isAtLeast(minimumAge)
            switch atLeast {
            case true?: break
            case false?: refusal = .tooYoung(minimumAge: minimumAge)
            case nil:
                // Without a known age an install is refused; a load stands on
                // the check its install passed, unless a parent supervises.
                if phase == .install || supervision.isSupervised {
                    refusal = .ageNotConfirmed(minimumAge: minimumAge)
                }
            }
        }
        if case .supervised(let installs, let limit) = supervision {
            if !source.isCurated, !installs { refusal = refusal ?? .ageNotConfirmed(minimumAge: minimumAge) }
            if let limit, minimumAge > limit { refusal = refusal ?? .ageNotConfirmed(minimumAge: minimumAge) }
            // Under the system's parental controls a parent can approve
            // anything refused.
            if refusal != nil { return .needsParentApproval(minimumAge: minimumAge, unlisted: !source.isCurated) }
        }
        return refusal
    }
}

// MARK: platform inputs

/// Asks for the user's age at the moment of a decision.
@MainActor
protocol AgeSource: AnyObject {
    func currentAgeRange(gates: [Int]) async -> AgeAssurance.Answer
}

/// Asks the system whether parental controls apply to the user, and passes
/// requests to a parent.
@MainActor
protocol SupervisionSource: AnyObject {
    func status() async -> SystemParentalControls.Status
    func askParent(_ description: String) async -> SystemParentalControls.Request
}

/// The platform's age signal through SwiftOpenUI: Declared Age Range on
/// Apple platforms, the systemd user record on Linux.
@MainActor
final class PlatformAgeSource: AgeSource {
    func currentAgeRange(gates: [Int]) async -> AgeAssurance.Answer {
        await AgeAssurance.currentAgeRange(gates: gates)
    }
}

/// The system's parental controls through SwiftOpenUI: Screen Time signals
/// and PermissionKit on Apple platforms, malcontent on Linux.
@MainActor
final class PlatformSupervisionSource: SupervisionSource {
    func status() async -> SystemParentalControls.Status { await SystemParentalControls.status() }
    func askParent(_ description: String) async -> SystemParentalControls.Request {
        await SystemParentalControls.askParent(description)
    }
}

// MARK: policy

/// The one place install, load and catalog decisions are made. Each decision
/// asks the platform for the user's age and parental controls at that moment
/// and combines them with the profile's birthday bound (`ProfileAgeRange`)
/// and parents' approvals (`ParentalApprovals`). One policy per profile per
/// app (`shared`), so every window sees the same state live.
@MainActor
final class SourceAccessPolicy {
    let classifier: any SourceClassifier
    let profileAge: ProfileAgeRange
    let approvals: ParentalApprovals
    let supervisionSource: any SupervisionSource
    private let ageSource: any AgeSource
    /// Called when the age bound or the approvals change.
    var onChange: [@MainActor () -> Void] = []

    init(ageSource: any AgeSource, supervisionSource: any SupervisionSource,
         profileAge: ProfileAgeRange, approvals: ParentalApprovals,
         classifier: any SourceClassifier = CuratedSourceDatabase.shared) {
        self.ageSource = ageSource
        self.supervisionSource = supervisionSource
        self.profileAge = profileAge
        self.approvals = approvals
        self.classifier = classifier
        profileAge.onChange = { [weak self] in self?.onChange.forEach { $0() } }
        approvals.onChange = { [weak self] in self?.onChange.forEach { $0() } }
    }

    private static var shared: [String: SourceAccessPolicy] = [:]

    /// The app's policy for one profile. Windows that open the same profile
    /// over the same stores get the same instance. It listens for parents'
    /// answers for the app's lifetime.
    static func shared(stores: AppDataStores, profilePrefix: String,
                       profileChanges: ProfileChangeStore?) -> SourceAccessPolicy {
        let key = "\(ObjectIdentifier(stores.storage))|\(profilePrefix)"
        if let existing = shared[key] { return existing }
        let approvals = ParentalApprovals(storage: stores.storage, storageName: profilePrefix + "parental_approvals",
                                          profileChanges: profileChanges)
        let created = SourceAccessPolicy(
            ageSource: PlatformAgeSource(), supervisionSource: PlatformSupervisionSource(),
            profileAge: ProfileAgeRange(storage: stores.storage, storageName: profilePrefix + "age_range",
                                        profileChanges: profileChanges),
            approvals: approvals
        )
        shared[key] = created
        Task { [weak approvals] in
            for await response in SystemParentalControls.parentResponses() {
                await approvals?.resolve(response)
            }
        }
        return created
    }

    func classification(for config: PluginConfig) -> SourceClassification {
        classifier.classification(for: config)
    }

    /// Decides whether `config` may be installed.
    func approveInstall(_ config: PluginConfig) async -> Result<InstallApproval, PolicyDenial> {
        let inputs = await currentInputs(for: config)
        return PolicyRules.install(classification(for: config), age: inputs.age, supervision: inputs.supervision,
                                   parentApproved: inputs.approved)
    }

    /// Decides whether an installed plugin may run now and with which forced
    /// settings.
    func approveLoad(_ config: PluginConfig) async -> Result<LoadApproval, PolicyDenial> {
        let inputs = await currentInputs(for: config)
        return PolicyRules.load(classification(for: config), age: inputs.age, supervision: inputs.supervision,
                                parentApproved: inputs.approved, approvedSettings: inputs.approvedSettings)
    }

    /// Decides whether a plugin setting may change to `value`.
    func approveSettingChange(_ config: PluginConfig, setting: String, value: String) async -> PolicyDenial? {
        let inputs = await currentInputs(for: config)
        return PolicyRules.settingChange(classification(for: config), setting: setting, value: value,
                                         age: inputs.age, supervision: inputs.supervision,
                                         approvedSettings: inputs.approvedSettings)
    }

    /// How each catalog entry is shown, from one query for the list.
    func visibility(of configs: [PluginConfig]) async -> [String: CatalogVisibility] {
        let age = await currentAge()
        let supervision = Supervision(await supervisionSource.status())
        let approved = await approvals.current()
        var result: [String: CatalogVisibility] = [:]
        for config in configs {
            result[config.id] = PolicyRules.visibility(
                classification(for: config), age: age, supervision: supervision,
                parentApproved: approved.contains(config.id)
            )
        }
        return result
    }

    /// How each reviewed source is shown on the discovery page, from one
    /// query for the list.
    func visibility(ofReviewed entries: [CuratedSourceEntry]) async -> [String: CatalogVisibility] {
        let age = await currentAge()
        let supervision = Supervision(await supervisionSource.status())
        let approved = await approvals.current()
        var result: [String: CatalogVisibility] = [:]
        for entry in entries {
            result[entry.pluginID] = PolicyRules.visibility(
                entry.classification, age: age, supervision: supervision,
                parentApproved: approved.contains(entry.pluginID)
            )
        }
        return result
    }

    /// Asks a parent, through the system, to approve a rated setting of an
    /// installed source (YouTube's age-restricted videos, say).
    func askParent(pluginID: String, name: String, setting: String, settingName: String,
                   denial: PolicyDenial) async -> SystemParentalControls.Request {
        let age: Int
        switch denial {
        case .needsParentApproval(let rating, _), .tooYoung(let rating), .ageNotConfirmed(let rating): age = rating
        }
        let request = await supervisionSource.askParent(
            "Turn on “\(settingName)” in the Hummingbird source “\(name)”. It makes the source \(age)+."
        )
        if case .sent(let id) = request {
            await approvals.recordRequest(id: id, pluginID: ParentalApprovals.settingKey(pluginID, setting),
                                          name: "\(name): \(settingName)", sourceURL: "")
        }
        return request
    }

    /// Asks a parent, through the system, to approve a refused source.
    func askParent(pluginID: String, name: String, sourceURL: String,
                   denial: PolicyDenial) async -> SystemParentalControls.Request {
        let description: String
        switch denial {
        case .needsParentApproval(_, true):
            description = "Add the source “\(name)” to Hummingbird. It isn’t on Hummingbird’s reviewed list."
        case .needsParentApproval(let age, false), .tooYoung(let age), .ageNotConfirmed(let age):
            description = "Add the source “\(name)” to Hummingbird. It is rated \(age)+."
        }
        let request = await supervisionSource.askParent(description)
        if case .sent(let id) = request {
            await approvals.recordRequest(id: id, pluginID: pluginID, name: name, sourceURL: sourceURL)
        }
        return request
    }

    private func currentInputs(
        for config: PluginConfig
    ) async -> (age: AgeEvidence, supervision: Supervision, approved: Bool, approvedSettings: Set<String>) {
        let age = await currentAge()
        let supervision = Supervision(await supervisionSource.status())
        let approved = await approvals.current()
        let prefix = ParentalApprovals.settingKeyPrefix(config.id)
        let settings = Set(approved.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        return (age, supervision, approved.contains(config.id), settings)
    }

    /// Asks the platform now. A shared range tightens the profile's bound;
    /// declined and unavailable never write. The answer is combined with the
    /// bound for this decision only.
    private func currentAge(now: Date = Date()) async -> AgeEvidence {
        let device = AgeEvidence(await ageSource.currentAgeRange(gates: PolicyRules.ageGates))
        if case .range(let lower, _) = device { await profileAge.record(lowerBound: lower, now: now) }
        let bound = await profileAge.current()
        return PolicyRules.effectiveAge(device: device, profileMinimumAge: bound?.minimumAge(on: now))
    }
}
