import HummingbirdKit
import SwiftOpenUI
import BackendGTK4

@MainActor
struct HummingbirdGTKApp: App {
    var body: some Scene {
        WindowGroup("Hummingbird") { HummingbirdRoot() }
    }
}

MainActor.assumeIsolated { GTK4Backend().run(HummingbirdGTKApp.self) }
