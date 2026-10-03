import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

/// The app's root view with its model, for platform entry points (`Apps/iOS`, `Sources/JaybirdGTK`).
@MainActor
public struct JaybirdRoot: View {
    @State private var model = AppModel()
    #if canImport(SwiftUI)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    public init() {}
    public var body: some View {
        #if canImport(SwiftUI)
        RootView()
            .environment(model)
            .task { await model.plugins.checkForUpdates() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.library.flushHistory(); model.library.persistSubscriptionState() }
            }
        #else
        RootView()
            .environment(model)
            .task { await model.plugins.checkForUpdates() }
        #endif
    }
}
