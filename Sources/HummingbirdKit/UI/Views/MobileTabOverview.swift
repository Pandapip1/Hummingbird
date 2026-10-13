import Foundation
import SwiftOpenUI

/// Compact browser controls. On iOS the containing `TabView` presents these
/// through its native bottom-accessory area so they share the tab-bar chrome.
@MainActor
struct MobileBrowserToolbar: View {
    @Environment(AppModel.self) private var app
    @Binding var showingTabOverview: Bool

    var body: some View {
        HStack {
            BrowserBackButton(tab: app.activeTab)
                .frame(width: 44, height: 44)
            BrowserForwardButton(tab: app.activeTab)
                .frame(width: 44, height: 44)
            Spacer()
            AppSectionMenu()
                .frame(width: 44, height: 44)
            BrowserTabOverviewButton { showingTabOverview = true }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .font(.headline)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
