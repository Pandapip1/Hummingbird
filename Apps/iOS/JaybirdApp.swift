import SwiftUI

@main
struct JaybirdApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.plugins.checkForUpdates() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.library.flushHistory(); model.library.persistSubscriptionState() }
                }
        }
    }
}
