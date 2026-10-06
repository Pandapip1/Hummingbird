import Foundation
#if !canImport(WebKit)
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

/// Shown on platforms where WebKit is unavailable (e.g. tvOS). Sign-in requires
/// an embedded web view; without one, only a "not available" message is shown.
@MainActor
struct WebAuthSheet: View {
    let spec: WebAuthSpec
    let onFinish: (SourceAuth?) -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Sign in not available",
                systemImage: "safari.slash",
                description: Text("Sign in requires an embedded web browser, which is not available on this platform. Use the iPhone, iPad, or Mac app to sign in.")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(nil) }
                }
            }
            .navigationTitle(spec.title)
        }
    }
}
#endif
