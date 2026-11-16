import Foundation
import SwiftOpenUI

/// A toggle for a setting whose change takes a while to apply. While `apply`
/// runs, the switch shows neither on nor off, takes no taps, and a spinner
/// sits to its right; afterwards it shows the value actually in effect, which
/// is the old one, with the error below it, if applying failed. It never
/// pretends a change happened before it has.
///
/// The in-between switch is drawn from shapes, so it looks the same on every
/// platform, whether or not the platform's own switch has a mixed state.
@MainActor
struct PendingToggle<Label: View>: View {
    let isOn: Bool
    let apply: @MainActor (Bool) async throws -> Void
    @ViewBuilder let label: () -> Label
    @State private var applying = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if applying {
                HStack(spacing: 8) {
                    label()
                    Spacer(minLength: 8)
                    IndeterminateSwitch()
                    ProgressView()
                }
            } else {
                Toggle(isOn: Binding(get: { isOn }, set: { start($0) }), label: label)
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func start(_ value: Bool) {
        guard !applying, value != isOn else { return }
        applying = true
        failure = nil
        Task {
            do { try await apply(value) } catch { failure = error.localizedDescription }
            applying = false
        }
    }
}

/// A switch that is neither on nor off: a neutral track with a dash.
private struct IndeterminateSwitch: View {
    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 44, height: 26)
            .overlay(Capsule().fill(Color.secondary).frame(width: 14, height: 3))
    }
}
