import HummingbirdKit
import SwiftOpenUI
import BackendGTK4

@MainActor
struct HummingbirdGTKApp: App {
    var body: some Scene {
        WindowGroup("Hummingbird") { HummingbirdRoot() }
    }
}

MainActor.assumeIsolated {
    // JavaScriptCoreGTK and WebKitGTK share WTF's process-global main-thread
    // identity. Establish it here before plugin runtimes can initialize JSC on
    // their serial worker queues.
    do {
        try JSEngines.initializeDefaultRuntimeOnCurrentThread()
    } catch {
        fatalError("Could not initialize the shared JavaScript runtime: \(error)")
    }
    GTK4Backend().run(HummingbirdGTKApp.self)
}
