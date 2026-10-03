import JaybirdKit
import SwiftOpenUI
import BackendGTK4

@MainActor
struct JaybirdGTKApp: App {
    var body: some Scene {
        WindowGroup("Jaybird") { JaybirdRoot() }
    }
}

MainActor.assumeIsolated { GTK4Backend().run(JaybirdGTKApp.self) }
