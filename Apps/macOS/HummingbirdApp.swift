import SwiftUI
import HummingbirdKit

@main
struct HummingbirdApp: App {
    var body: some Scene {
        WindowGroup { HummingbirdRoot() }
            .defaultSize(width: 1000, height: 700)
    }
}
