import Foundation
import SwiftOpenUI
@testable import HummingbirdKit

/// An age source that answers with a fixed value and counts how often it is
/// asked, so tests can check that every decision asks afresh.
@MainActor
final class FixedAgeSource: AgeSource {
    var answer: AgeAssurance.Answer
    private(set) var requests = 0

    init(_ answer: AgeAssurance.Answer) { self.answer = answer }

    func currentAgeRange(gates: [Int]) async -> AgeAssurance.Answer {
        requests += 1
        return answer
    }
}

/// The system's parental controls, as a test sets them. Questions to a
/// parent get ids the test can answer with `ParentalApprovals.resolve`.
@MainActor
final class FixedSupervisionSource: SupervisionSource {
    var answer: SystemParentalControls.Status
    var canAsk = true
    private(set) var asked: [(id: UUID, description: String)] = []

    init(_ answer: SystemParentalControls.Status) { self.answer = answer }

    func status() async -> SystemParentalControls.Status { answer }

    func askParent(_ description: String) async -> SystemParentalControls.Request {
        guard canAsk else { return .unavailable }
        let id = UUID()
        asked.append((id, description))
        return .sent(id: id)
    }
}

/// A policy over in-memory storage with fixed platform answers (default: no
/// age source and no parental controls, which the policy treats as adult).
@MainActor
func makeTestPolicy(
    age: AgeAssurance.Answer = .unavailable,
    supervision: SystemParentalControls.Status = .notSupervised,
    classifier: any SourceClassifier = CuratedSourceDatabase.shared
) -> SourceAccessPolicy {
    SourceAccessPolicy(
        ageSource: FixedAgeSource(age), supervisionSource: FixedSupervisionSource(supervision),
        profileAge: ProfileAgeRange(storage: .inMemory(), storageName: "age_range", profileChanges: nil),
        approvals: ParentalApprovals(storage: .inMemory(), storageName: "approvals", profileChanges: nil),
        classifier: classifier
    )
}

/// A load approval made by the real rules for an adult without parental
/// controls, for tests that start runtimes directly.
func testLoadApproval(_ config: PluginConfig) -> LoadApproval {
    let source = CuratedSourceDatabase.shared.classification(for: config)
    guard case .success(let approval) = PolicyRules.load(
        source, age: .range(lower: 18, upper: nil), supervision: .none, parentApproved: false
    ) else { preconditionFailure("an adult without parental controls may run any source") }
    return approval
}
